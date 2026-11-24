-- Teardown only, not a step down to 3: it runs before 0001_queue.down.sql, which drops the tables (the trigger,
-- columns and constraint with them); a no-op below migration 5
DROP FUNCTION IF EXISTS cancel_task(text);
DROP FUNCTION IF EXISTS tasks_submitter() CASCADE;
