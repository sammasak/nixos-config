-- Each slot a runner claims for, with the agents it offers, as of its last claim. submit_task refuses a task whose
-- agent no slot seen in the last day offers, which would otherwise wait queued with no signal. A day outlasts the
-- longest claim and a weeknight poweroff, not a weekend one: an agent only a power-window host offers is refused then.
-- A slot dropped from its host's configuration ages out. From here the shape check is submit_task_shaped: a later
-- migration that replaces submit_task drops this check, and may apply after this one on a live database.
CREATE TABLE slots (
  host text NOT NULL,
  id text NOT NULL,
  agents jsonb NOT NULL,
  seen_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (host, id)
);
GRANT SELECT, INSERT, UPDATE (agents, seen_at) ON slots TO exec_pool_runner;

-- the shape check and the insert stay 0002's; the submitter reaches them only through the agent check
ALTER FUNCTION submit_task(jsonb) RENAME TO submit_task_shaped;
REVOKE ALL ON FUNCTION submit_task_shaped(jsonb) FROM exec_pool_submit;
CREATE FUNCTION submit_task(p_spec jsonb, OUT o_task text, OUT o_attempt text, OUT o_duplicate boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  -- NULL for what is not a task: submit_task_shaped refuses that, and an agent it does not take
  agent text := CASE WHEN jsonb_typeof(p_spec->'command') = 'object' THEN p_spec->'command'->>'agent' END;
  offered text;
BEGIN
  IF agent IN ('claude', 'codex', 'pi') AND NOT EXISTS (
    SELECT FROM slots WHERE agents ? agent AND seen_at > now() - interval '1 day'
  ) THEN
    SELECT string_agg(DISTINCT a, ', ' ORDER BY a) INTO offered
      FROM slots, jsonb_array_elements_text(agents) a
      WHERE seen_at > now() - interval '1 day' AND a <> 'none';
    RAISE EXCEPTION 'no slot seen in the last day offers agent %, so nothing would claim the task (offered: %)',
      agent, coalesce(offered, 'nothing') USING ERRCODE = '22023';
  END IF;
  SELECT s.o_task, s.o_attempt, s.o_duplicate INTO o_task, o_attempt, o_duplicate FROM submit_task_shaped(p_spec) s;
END $$;
REVOKE ALL ON FUNCTION submit_task(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION submit_task(jsonb) TO exec_pool_submit;

INSERT INTO schema_migrations (version) VALUES (8);
