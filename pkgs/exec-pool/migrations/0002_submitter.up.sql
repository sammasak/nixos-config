-- exec_pool_submit (homelab.postgresql.clients in modules/homelab/exec-pool.nix): submit a task and read the queue,
-- nothing else. An attempt it inserts takes every default, so it starts queued, unplaced at epoch 0; it changes no row
-- and reads no receipt. 0001_queue.down.sql drops these grants with the tables.
GRANT SELECT, INSERT (id, idempotency_key, spec, max_attempts) ON tasks TO exec_pool_submit;
GRANT SELECT, INSERT (id, task_id) ON attempts TO exec_pool_submit;
GRANT SELECT, INSERT ON events TO exec_pool_submit;
GRANT USAGE ON SEQUENCE events_id_seq TO exec_pool_submit;

INSERT INTO schema_migrations (version) VALUES (2);
