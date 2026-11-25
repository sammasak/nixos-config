-- Teardown only, before 0009_session.down.sql; a no-op below migration 23
DROP FUNCTION IF EXISTS continue_after(text, int8, text);
