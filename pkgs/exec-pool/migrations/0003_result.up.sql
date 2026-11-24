-- What an attempt produced, bounded: the adapter's outcome, the exit code and the end of its output, which
-- the runner writes once a settle took the attempt off its slot. The submitter reads it beside the state; the
-- prompt stays in tasks, and the output on the host stays where the helper wrote it.
CREATE TABLE results (
  attempt_id text PRIMARY KEY REFERENCES attempts (id),
  lease_epoch bigint NOT NULL CHECK (lease_epoch >= 0),
  -- NULL: the task's argv never ran, or ended with no verdict to read
  outcome text CHECK (outcome IN ('succeeded', 'failed', 'needs_review')),
  exit_code integer,
  output text NOT NULL CHECK (octet_length(output) <= 16384),
  recorded_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON results TO exec_pool_submit;

INSERT INTO schema_migrations (version) VALUES (3);
