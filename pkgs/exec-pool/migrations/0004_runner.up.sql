-- exec_pool_runner (homelab.postgresql.remoteClients in modules/homelab/exec-pool.nix) is a remote slot's runner: it
-- claims, heartbeats, settles and reconciles attempts and records their results, and does nothing else. It reads the
-- task it runs and writes no task, so it cannot queue work; of an attempt it writes only the lease's columns, never its
-- task or pins, and of a result never its attempt; events and receipts it only appends. The role exists before this
-- runs (postgresql-setup's ensureUsers, remoteRunners on or off); the down migrations drop these grants with the tables.
-- Column grants bound what it writes, not which transitions: attempts_fence holds the epoch, lease-from-queued and a
-- settled attempt final, but a runner with this password could still settle a queued attempt or append events.
GRANT SELECT ON tasks, attempts TO exec_pool_runner;
-- an event's id alone, for INSERT … RETURNING id
GRANT SELECT (id) ON events TO exec_pool_runner;
GRANT UPDATE (status, lease_epoch, tries, host, slot, fence, lease_deadline, checkpoint, changed_at) ON attempts
  TO exec_pool_runner;
GRANT INSERT ON events, receipts TO exec_pool_runner;
GRANT USAGE ON SEQUENCE events_id_seq TO exec_pool_runner;
GRANT SELECT, INSERT ON results TO exec_pool_runner;
GRANT UPDATE (lease_epoch, outcome, exit_code, output, recorded_at) ON results TO exec_pool_runner;

INSERT INTO schema_migrations (version) VALUES (4);
