-- Teardown only, before 0009_session.down.sql; a no-op below migration 14
DROP FUNCTION IF EXISTS wake_at(text, timestamptz, text);
DROP FUNCTION IF EXISTS send_timer(text, text, timestamptz);
