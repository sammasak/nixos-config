-- Teardown only, before 0009_session.down.sql and 0001_queue.down.sql: turns references attempts; a no-op below
-- migration 10
DROP VIEW IF EXISTS session_gc;
DROP TABLE IF EXISTS turns;
