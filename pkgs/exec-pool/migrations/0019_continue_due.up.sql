-- A park after a turn that ended in an error leaves its continue due later (queue.rs ERROR_BACKOFF_SECS), so a rate
-- limit is not met again at once; the runner writes that row's due_at, still no body.
GRANT INSERT (due_at) ON inbox TO exec_pool_runner;

-- additive: a binary at 9 to 18 writes no due_at on a continue, and delivers one that has it once it is due
INSERT INTO schema_migrations (version, floor) VALUES (19, 9);
