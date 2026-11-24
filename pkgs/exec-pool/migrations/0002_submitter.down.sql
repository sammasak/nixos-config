-- before 0001_queue.down.sql, which cannot drop tasks while the view depends on it; a no-op at migration 1
DROP VIEW IF EXISTS task_summaries;
DROP FUNCTION IF EXISTS submit_task(jsonb);
