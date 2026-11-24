-- Teardown only, not a step down to 7: it runs before 0002_submitter.down.sql, which drops submit_task; a no-op below
-- migration 8
DROP FUNCTION IF EXISTS submit_task_shaped(jsonb);
DROP TABLE IF EXISTS slots;
