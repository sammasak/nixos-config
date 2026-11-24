-- Teardown only, before 0001_queue.down.sql, which cannot drop tasks while the inbox references it; a no-op below
-- migration 9
DROP FUNCTION IF EXISTS send_message(text, text);
DROP FUNCTION IF EXISTS start_session(jsonb);
DROP TABLE IF EXISTS inbox;
