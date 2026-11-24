-- A turn's agent output as its runner last read it from the host that runs it (pkgs/exec-pool/src/turn_log.rs): the
-- tail, and `start`, its first byte's offset in the whole output. The runner rewrites it at every heartbeat, so
-- `exec-pool logs` reads a running turn from any host. Only what the agent printed, which its transcript holds too.
CREATE TABLE turn_logs (
  attempt_id text NOT NULL REFERENCES attempts (id),
  lease_epoch bigint NOT NULL CHECK (lease_epoch >= 0),
  start bigint NOT NULL CHECK (start >= 0),
  log bytea NOT NULL CHECK (octet_length(log) <= 262144),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (attempt_id, lease_epoch)
);
GRANT SELECT ON turn_logs TO exec_pool_submit;
-- SELECT for the upsert's conflict check
GRANT SELECT, INSERT, UPDATE (start, log, updated_at) ON turn_logs TO exec_pool_runner;

-- additive: a binary at 9 to 14 writes and reads no log
INSERT INTO schema_migrations (version, floor) VALUES (15, 9);
