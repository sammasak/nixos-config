-- Teardown only, before 0001_queue.down.sql, which cannot drop the tables the view reads
DROP VIEW IF EXISTS session_summaries;
