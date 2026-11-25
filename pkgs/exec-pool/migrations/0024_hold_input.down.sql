-- Teardown only, before 0009_session.down.sql; a no-op below migration 24
DROP FUNCTION IF EXISTS hold_input(text, int8, int8);
