-- A task may name the capabilities it requires (`exec-pool submit --requires NAME`): each slot records the ones its host
-- declares (homelab.execPool.capabilities) with every claim, the claim takes only a slot that offers them all
-- (TaskSpec::fits), and submit_task refuses a task no slot seen in the last day offers them to, with its agent, under
-- its own SQLSTATE (QueueError::Unoffered) rather than leave it queued for ever. A slot of a runner before 28 keeps
-- '[]', so until its host is deployed it offers none.
ALTER TABLE slots ADD COLUMN capabilities jsonb NOT NULL DEFAULT '[]';
GRANT UPDATE (capabilities) ON slots TO exec_pool_runner;

-- 0002's shape check with `capabilities` a sorted list of distinct names, at most 8, instead of only `[]`: what
-- serializing a TaskSpec writes, so the same task again compares equal under its key
CREATE OR REPLACE FUNCTION submit_task_shaped(p_spec jsonb, OUT o_task text, OUT o_attempt text,
  OUT o_duplicate boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  cmd jsonb := p_spec->'command';
  src jsonb := p_spec->'source';
  argv jsonb := cmd->'argv';
  caps jsonb := p_spec->'capabilities';
  known jsonb;
BEGIN
  -- one IF per level: the keys of something that is not an object would raise instead of refuse
  IF jsonb_typeof(p_spec) IS DISTINCT FROM 'object' OR jsonb_typeof(cmd) IS DISTINCT FROM 'object'
     OR jsonb_typeof(src) IS DISTINCT FROM 'object' OR jsonb_typeof(argv) IS DISTINCT FROM 'array'
     OR jsonb_typeof(caps) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'submit_task: not a task' USING ERRCODE = '22023';
  END IF;
  IF (
    (SELECT array_agg(k) FROM jsonb_object_keys(p_spec) k) <@ ARRAY['schema_version', 'idempotency_key', 'source',
      'command', 'capabilities', 'resource_class', 'credential_class', 'retry', 'pins']
    AND (SELECT array_agg(k) FROM jsonb_object_keys(p_spec) k) @> ARRAY['schema_version', 'idempotency_key',
      'source', 'command', 'capabilities', 'resource_class', 'credential_class', 'retry', 'pins']
    AND (SELECT array_agg(k) FROM jsonb_object_keys(src) k) <@ ARRAY['repo', 'rev']
    AND (SELECT array_agg(k) FROM jsonb_object_keys(src) k) @> ARRAY['repo', 'rev']
    AND (SELECT array_agg(k) FROM jsonb_object_keys(cmd) k) <@ ARRAY['agent', 'argv', 'workdir']
    AND (SELECT array_agg(k) FROM jsonb_object_keys(cmd) k) @> ARRAY['agent', 'argv', 'workdir']
    AND p_spec->'schema_version' = '1' AND p_spec->'pins' = '{}'
    AND jsonb_array_length(caps) <= 8
    AND NOT EXISTS (SELECT FROM jsonb_array_elements(caps) c
      WHERE jsonb_typeof(c) <> 'string' OR c #>> '{}' !~ '^[a-z][a-z0-9-]{0,31}$')
    AND caps = coalesce((SELECT jsonb_agg(DISTINCT c COLLATE "C" ORDER BY c COLLATE "C")
      FROM jsonb_array_elements_text(caps) c), '[]')
    AND p_spec->'retry' = '{"max_attempts": 1}' AND p_spec->'resource_class' = '"small"'
    AND p_spec->'credential_class' = '"slot"'
    AND jsonb_typeof(p_spec->'idempotency_key') = 'string' AND p_spec->>'idempotency_key' <> ''
    AND jsonb_typeof(src->'repo') = 'string' AND src->>'repo' LIKE 'https://_%'
    AND jsonb_typeof(src->'rev') = 'string' AND src->>'rev' <> '' AND src->>'rev' NOT LIKE '-%'
    AND cmd->'agent' IN ('"claude"', '"codex"', '"pi"')
    AND jsonb_typeof(cmd->'workdir') = 'string' AND cmd->>'workdir' <> '' AND cmd->>'workdir' NOT LIKE '/%'
    AND cmd->>'workdir' !~ '(^|/)\.\.(/|$)'
    AND jsonb_array_length(argv) IN (1, 2)
    AND NOT EXISTS (SELECT FROM jsonb_array_elements(argv) a WHERE jsonb_typeof(a) <> 'string')
    AND argv->>0 <> '' AND (jsonb_array_length(argv) = 1 OR (argv->>1 <> '' AND argv->>1 NOT LIKE '-%'))
  ) IS NOT TRUE THEN
    RAISE EXCEPTION 'submit_task: not a task exec-pool submit makes' USING ERRCODE = '22023';
  END IF;
  o_task := 'cli-' || left(encode(sha256(convert_to(p_spec->>'idempotency_key', 'UTF8')), 'hex'), 16);
  o_attempt := o_task || '.a';
  p_spec := p_spec || jsonb_build_object('id', o_task);
  INSERT INTO tasks (id, idempotency_key, spec, max_attempts)
    VALUES (o_task, p_spec->>'idempotency_key', p_spec, 1) ON CONFLICT DO NOTHING;
  IF NOT FOUND THEN
    SELECT t.spec INTO known FROM tasks t WHERE t.idempotency_key = p_spec->>'idempotency_key';
    IF known IS DISTINCT FROM p_spec THEN
      RAISE EXCEPTION 'idempotency key % already names a different task', p_spec->>'idempotency_key'
        USING ERRCODE = '23505';
    END IF;
    SELECT a.id INTO o_attempt FROM attempts a WHERE a.task_id = o_task;
    o_duplicate := true;
    RETURN;
  END IF;
  INSERT INTO attempts (id, task_id) VALUES (o_attempt, o_task);
  INSERT INTO events (task_id, attempt_id, lease_epoch, from_status, to_status, reason, in_state_ms, since_submit_ms)
    VALUES (o_task, o_attempt, 0, NULL, 'queued', 'submit', 0, 0);
  o_duplicate := false;
END $$;

-- 0008's agent check, then the capabilities: both against the slots seen in the last day. start_session and the
-- priority forms call this one, so they refuse alike.
CREATE OR REPLACE FUNCTION submit_task(p_spec jsonb, OUT o_task text, OUT o_attempt text, OUT o_duplicate boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  -- NULL for what is not a task: submit_task_shaped refuses that, and an agent it does not take
  agent text := CASE WHEN jsonb_typeof(p_spec->'command') = 'object' THEN p_spec->'command'->>'agent' END;
  wanted jsonb := CASE WHEN jsonb_typeof(p_spec->'capabilities') = 'array' THEN p_spec->'capabilities' END;
  offered text;
  missing text;
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
  -- a list that is not of sorted, distinct names is submit_task_shaped's to refuse, as not a task
  IF wanted IS DISTINCT FROM coalesce((SELECT jsonb_agg(DISTINCT c COLLATE "C" ORDER BY c COLLATE "C")
      FROM jsonb_array_elements_text(wanted) c WHERE c ~ '^[a-z][a-z0-9-]{0,31}$'), '[]') THEN
    wanted := NULL;
  END IF;
  IF agent IN ('claude', 'codex', 'pi') AND wanted IS NOT NULL AND NOT EXISTS (
    SELECT FROM slots WHERE agents ? agent AND capabilities @> wanted AND seen_at > now() - interval '1 day'
  ) THEN
    SELECT string_agg(DISTINCT w, ', ' ORDER BY w) INTO missing FROM jsonb_array_elements_text(wanted) w
      WHERE NOT EXISTS (SELECT FROM slots
        WHERE agents ? agent AND capabilities ? w AND seen_at > now() - interval '1 day');
    SELECT string_agg(DISTINCT c, ', ' ORDER BY c) INTO offered
      FROM slots, jsonb_array_elements_text(capabilities) c
      WHERE agents ? agent AND seen_at > now() - interval '1 day';
    RAISE EXCEPTION 'no slot seen in the last day offers capability % with agent %, so nothing would claim the task (offered: %)',
      coalesce(missing, (SELECT string_agg(w, ' and ' ORDER BY w) FROM jsonb_array_elements_text(wanted) w)
        || ' together'), agent, coalesce(offered, 'nothing') USING ERRCODE = 'XP412';
  END IF;
  SELECT s.o_task, s.o_attempt, s.o_duplicate INTO o_task, o_attempt, o_duplicate FROM submit_task_shaped(p_spec) s;
END $$;

-- additive: a binary at 9 to 27 writes no slot capabilities and submits none, which this one takes as before
INSERT INTO schema_migrations (version, floor) VALUES (28, 9);
