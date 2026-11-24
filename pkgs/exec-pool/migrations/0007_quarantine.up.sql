-- floor: the oldest binary (its migration VERSION) whose reads and writes stay correct on a database with this
-- migration applied, for itself and for the newer binaries that come back after it. A binary older than the schema
-- serves it while every applied migration's floor is at most its own version, so a rollback across an additive
-- migration keeps the queue up. NULL, as before this, is the migration's own version: refused.
ALTER TABLE schema_migrations ADD COLUMN floor integer;

-- A slot its runner could not reset (dev-env-reset@ refused: an agent running, or unpushed work): the runner claims
-- nothing for it until an operator clears the cause, removes the runner's marker and restarts it; a reset that then
-- succeeds deletes the row. exec_pool_slots{state="quarantined"} counts them.
CREATE TABLE quarantined_slots (
  host text NOT NULL,
  slot text NOT NULL,
  reason text NOT NULL CHECK (octet_length(reason) <= 4096),
  since timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (host, slot)
);
GRANT SELECT, INSERT, UPDATE, DELETE ON quarantined_slots TO exec_pool_runner;

-- additive: the previous binary neither reads the floor nor touches the table
INSERT INTO schema_migrations (version, floor) VALUES (7, 6);
