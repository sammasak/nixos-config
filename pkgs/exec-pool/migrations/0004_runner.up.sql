-- exec_pool_runner (homelab.postgresql.remoteClients in modules/homelab/exec-pool.nix) is a remote slot's runner: it
-- claims, heartbeats, settles and reconciles attempts, and does nothing else. It reads the task it runs and writes no
-- task, so it cannot queue work, and of an attempt it writes only the lease's columns, never its task or pins; events
-- and receipts it only appends. The role exists before this runs (postgresql-setup's ensureUsers); 0001's down drops
-- these grants with the tables.
GRANT SELECT ON tasks, attempts, events TO exec_pool_runner;
GRANT UPDATE (status, lease_epoch, tries, host, slot, fence, lease_deadline, checkpoint, changed_at) ON attempts
  TO exec_pool_runner;
GRANT INSERT ON events, receipts TO exec_pool_runner;
GRANT USAGE ON SEQUENCE events_id_seq TO exec_pool_runner;

INSERT INTO schema_migrations (version) VALUES (4);
