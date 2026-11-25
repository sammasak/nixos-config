-- Teardown only, before 0009_session.down.sql; a no-op below migration 24
DROP TRIGGER IF EXISTS inbox_release_held_input ON inbox;
DROP FUNCTION IF EXISTS release_held_input();
DROP FUNCTION IF EXISTS hold_input(text, text, int8, int8, int8);
