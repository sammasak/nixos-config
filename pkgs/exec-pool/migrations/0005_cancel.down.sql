-- before 0001_queue.down.sql, which drops the tables (and the trigger with tasks); a no-op below migration 5
DROP FUNCTION IF EXISTS cancel_task(text);
DROP FUNCTION IF EXISTS tasks_submitter() CASCADE;
