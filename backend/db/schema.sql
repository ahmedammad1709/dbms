-- Smart Skill Exchange Platform (Neon / Postgres) schema
-- Run this in Neon SQL Editor (or psql) BEFORE starting the backend.
--
-- Notes
-- - `auth_user_id` / `user_id` values come from Neon Auth (UUID strings).
-- - The backend uses ON CONFLICT on (auth_user_id) and (auth_user_id, skill_id),
--   so the UNIQUE constraints below are required.

BEGIN;

-- Optional: only needed if you later want server-generated UUIDs.
-- CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- =========================
-- Core user metadata
-- =========================

CREATE TABLE IF NOT EXISTS user_roles (
  id            BIGSERIAL PRIMARY KEY,
  auth_user_id  UUID NOT NULL UNIQUE,
  role          TEXT NOT NULL DEFAULT 'user',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS user_profiles (
  id            BIGSERIAL PRIMARY KEY,
  auth_user_id  UUID NOT NULL UNIQUE,
  email         TEXT,
  full_name     TEXT,
  bio           TEXT,
  credits       INTEGER NOT NULL DEFAULT 0,
  is_suspended  BOOLEAN NOT NULL DEFAULT false,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_user_profiles_auth_user_id ON user_profiles(auth_user_id);

-- Used by frontend Neon Data API (optional) and backend profile/role reads.
-- Keep it simple: one role row per auth user.

-- =========================
-- Skills
-- =========================

CREATE TABLE IF NOT EXISTS skills (
  id          BIGSERIAL PRIMARY KEY,
  name        TEXT NOT NULL,
  category    TEXT,
  skill_type  TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_skills_lower_name ON skills((lower(name)));
CREATE INDEX IF NOT EXISTS idx_skills_category ON skills(category);
CREATE INDEX IF NOT EXISTS idx_skills_skill_type ON skills(skill_type);

CREATE TABLE IF NOT EXISTS user_skills (
  id           BIGSERIAL PRIMARY KEY,
  auth_user_id UUID NOT NULL,
  skill_id     BIGINT NOT NULL REFERENCES skills(id) ON DELETE CASCADE,
  proficiency  INTEGER,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT user_skills_unique_user_skill UNIQUE (auth_user_id, skill_id)
);

CREATE INDEX IF NOT EXISTS idx_user_skills_auth_user_id ON user_skills(auth_user_id);
CREATE INDEX IF NOT EXISTS idx_user_skills_skill_id ON user_skills(skill_id);

-- =========================
-- Learning requests + sessions
-- =========================

CREATE TABLE IF NOT EXISTS learning_requests (
  id                   BIGSERIAL PRIMARY KEY,
  learner_id            UUID NOT NULL,
  teacher_id            UUID NOT NULL,
  user_skill_id         BIGINT NOT NULL REFERENCES user_skills(id) ON DELETE CASCADE,
  message               TEXT,
  status                TEXT NOT NULL DEFAULT 'pending',
  preferred_date        DATE,
  preferred_start_time  TIME,
  duration_minutes      INTEGER,
  exchange_type         TEXT NOT NULL,
  offered_skill_id      BIGINT REFERENCES skills(id) ON DELETE SET NULL,
  offered_credit_amount INTEGER,
  teacher_seen          BOOLEAN NOT NULL DEFAULT false,
  learner_seen          BOOLEAN NOT NULL DEFAULT false,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT learning_requests_exchange_type_chk CHECK (exchange_type IN ('skill','credits')),
  CONSTRAINT learning_requests_status_chk CHECK (status IN ('pending','accepted','rejected')),
  CONSTRAINT learning_requests_learner_teacher_chk CHECK (learner_id <> teacher_id)
);

CREATE INDEX IF NOT EXISTS idx_learning_requests_teacher_status ON learning_requests(teacher_id, status);
CREATE INDEX IF NOT EXISTS idx_learning_requests_learner_status ON learning_requests(learner_id, status);
CREATE INDEX IF NOT EXISTS idx_learning_requests_user_skill_id ON learning_requests(user_skill_id);
CREATE INDEX IF NOT EXISTS idx_learning_requests_teacher_seen ON learning_requests(teacher_id, teacher_seen);
CREATE INDEX IF NOT EXISTS idx_learning_requests_learner_seen ON learning_requests(learner_id, learner_seen);

-- Auto-maintain updated_at for updates that forget to set it.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc WHERE proname = 'set_updated_at'
  ) THEN
    CREATE FUNCTION set_updated_at() RETURNS trigger AS $$
    BEGIN
      NEW.updated_at = now();
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgname = 'trg_learning_requests_set_updated_at'
  ) THEN
    CREATE TRIGGER trg_learning_requests_set_updated_at
    BEFORE UPDATE ON learning_requests
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS sessions (
  id              BIGSERIAL PRIMARY KEY,
  request_id      BIGINT NOT NULL UNIQUE REFERENCES learning_requests(id) ON DELETE CASCADE,
  learner_id      UUID NOT NULL,
  teacher_id      UUID NOT NULL,
  scheduled_date  DATE NOT NULL,
  start_time      TIME NOT NULL,
  end_time        TIME NOT NULL,
  duration_minutes INTEGER NOT NULL,
  chat_enabled_at TIMESTAMPTZ,
  chat_expires_at TIMESTAMPTZ,
  meeting_link    TEXT,
  status          TEXT NOT NULL DEFAULT 'scheduled',
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT sessions_status_chk CHECK (status IN ('scheduled','cancelled'))
);

CREATE INDEX IF NOT EXISTS idx_sessions_learner_id ON sessions(learner_id);
CREATE INDEX IF NOT EXISTS idx_sessions_teacher_id ON sessions(teacher_id);
CREATE INDEX IF NOT EXISTS idx_sessions_chat_expires_at ON sessions(chat_expires_at);

-- =========================
-- Messaging + notifications
-- =========================

CREATE TABLE IF NOT EXISTS messages (
  id           BIGSERIAL PRIMARY KEY,
  sender_id    UUID NOT NULL,
  receiver_id  UUID NOT NULL,
  request_id   BIGINT REFERENCES learning_requests(id) ON DELETE SET NULL,
  session_id   BIGINT REFERENCES sessions(id) ON DELETE SET NULL,
  message_text TEXT NOT NULL,
  is_read      BOOLEAN NOT NULL DEFAULT false,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_messages_sender_created ON messages(sender_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_messages_receiver_is_read ON messages(receiver_id, is_read);
CREATE INDEX IF NOT EXISTS idx_messages_session_id ON messages(session_id);

CREATE TABLE IF NOT EXISTS notifications (
  id           BIGSERIAL PRIMARY KEY,
  user_id      UUID NOT NULL,
  title        TEXT NOT NULL,
  message      TEXT NOT NULL,
  type         TEXT NOT NULL,
  reference_id BIGINT,
  is_read      BOOLEAN NOT NULL DEFAULT false,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_notifications_user_read ON notifications(user_id, is_read);
CREATE INDEX IF NOT EXISTS idx_notifications_user_created ON notifications(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_notifications_type_ref ON notifications(type, reference_id);

-- =========================
-- Wallet / credits
-- =========================

CREATE TABLE IF NOT EXISTS credit_transactions (
  id               BIGSERIAL PRIMARY KEY,
  sender_id        UUID,
  receiver_id      UUID,
  user_id          UUID NOT NULL,
  amount           INTEGER NOT NULL,
  transaction_type TEXT NOT NULL,
  request_id       BIGINT REFERENCES learning_requests(id) ON DELETE SET NULL,
  session_id       BIGINT REFERENCES sessions(id) ON DELETE SET NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_credit_transactions_user_created ON credit_transactions(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_credit_transactions_type ON credit_transactions(transaction_type);

-- =========================
-- Reviews
-- =========================

CREATE TABLE IF NOT EXISTS reviews (
  id              BIGSERIAL PRIMARY KEY,
  session_id      BIGINT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  reviewer_id     UUID NOT NULL,
  reviewed_user_id UUID NOT NULL,
  rating          INTEGER NOT NULL,
  comment         TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT reviews_rating_chk CHECK (rating >= 1 AND rating <= 5),
  CONSTRAINT reviews_unique UNIQUE (session_id, reviewer_id, reviewed_user_id)
);

CREATE INDEX IF NOT EXISTS idx_reviews_reviewed_user_id ON reviews(reviewed_user_id);
CREATE INDEX IF NOT EXISTS idx_reviews_session_id ON reviews(session_id);

COMMIT;

-- =========================
-- Optional seed data
-- =========================
-- The app can create skills on demand when users add them.
-- If you want a small starting catalog, uncomment and run:
--
-- INSERT INTO skills(name, category, skill_type) VALUES
--   ('JavaScript', 'Programming', 'technical'),
--   ('React', 'Programming', 'technical'),
--   ('UI/UX Design', 'Design', 'creative')
-- ON CONFLICT DO NOTHING;
