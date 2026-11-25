-- A park after a turn that ended in a memory kill (queue.rs MEMORY_KILLED) writes its continue's body: what the
-- kernel killed, which the next turn is told.
GRANT INSERT (body) ON inbox TO exec_pool_runner;

-- additive: a binary at 9 to 22 writes no body on a continue, and delivers one that has it
INSERT INTO schema_migrations (version, floor) VALUES (23, 9);
