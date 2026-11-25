-- A session's agent transcript as its last park left it (Store::park), which the next turn writes back for
-- `--resume` on whichever host claims it. This is its only copy: it holds tool output, so it never goes to the
-- repository with the branch. Bounded per session, compressed by TOAST, and removed once the session is final.
CREATE TABLE transcripts (
  task_id text PRIMARY KEY REFERENCES tasks (id),
  lease_epoch bigint NOT NULL CHECK (lease_epoch >= 0),
  -- the directory under ~/.claude/projects the agent kept it in: one path component
  project text NOT NULL CHECK (project ~ '^[A-Za-z0-9._-]{1,255}$' AND project NOT IN ('.', '..')),
  body bytea NOT NULL CHECK (octet_length(body) <= 33554432),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE transcripts ALTER COLUMN body SET COMPRESSION lz4;
-- SELECT for the upsert's conflict check and the claim
GRANT SELECT, INSERT, UPDATE (lease_epoch, project, body, updated_at) ON transcripts TO exec_pool_runner;

-- a final session is never resumed: send_message refuses it
CREATE FUNCTION transcripts_drop_final() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  DELETE FROM transcripts WHERE task_id = NEW.task_id;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION transcripts_drop_final() FROM PUBLIC;
CREATE TRIGGER transcripts_drop_final AFTER UPDATE OF status ON attempts
  FOR EACH ROW WHEN (NEW.status IN ('succeeded', 'failed', 'cancelled'))
  EXECUTE FUNCTION transcripts_drop_final();

-- additive: a binary at 9 to 16 reads a park's checkpoint as a tree on no host and sends that turn to review; this
-- one reads its checkpoints, their hosts dropped
INSERT INTO schema_migrations (version, floor) VALUES (17, 9);
