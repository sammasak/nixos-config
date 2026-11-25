-- Teardown only, before 0010_session_metrics.down.sql drops the table
ALTER TABLE IF EXISTS turns DROP COLUMN IF EXISTS delivered;
