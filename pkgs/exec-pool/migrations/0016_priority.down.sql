-- Teardown only, before 0009_session.down.sql; a no-op below migration 16
DROP FUNCTION IF EXISTS start_session(jsonb, integer);
DROP FUNCTION IF EXISTS submit_task(jsonb, integer);
