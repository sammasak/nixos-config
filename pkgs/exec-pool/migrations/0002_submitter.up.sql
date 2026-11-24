-- exec_pool_submit (homelab.postgresql.clients in modules/homelab/exec-pool.nix) holds no table write: it queues
-- through submit_task alone, which takes only the task `exec-pool submit` builds (an agent, an https repo, a rev, a
-- workdir in the checkout, a prompt and maybe a model; no capability, one attempt, credential class `slot`), so a
-- submitter cannot choose its own policy, forge an event or queue a spec that every claim would fail to decode. It
-- reads attempts, events and task_summaries, which leaves out the prompt.
CREATE VIEW task_summaries AS
  SELECT id, submitted_at, spec->'command'->'agent' AS agent, spec->'source'->'repo' AS repo,
    spec->'source'->'rev' AS rev, spec->'command'->'workdir' AS workdir
  FROM tasks;

-- The task's id is the queue's, from its key: a co-submitter cannot take the id another's submission will need.
CREATE FUNCTION submit_task(p_spec jsonb, OUT o_task text, OUT o_attempt text, OUT o_duplicate boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  cmd jsonb := p_spec->'command';
  src jsonb := p_spec->'source';
  argv jsonb := cmd->'argv';
  known jsonb;
BEGIN
  -- one IF per level: the keys of something that is not an object would raise instead of refuse
  IF jsonb_typeof(p_spec) IS DISTINCT FROM 'object' OR jsonb_typeof(cmd) IS DISTINCT FROM 'object'
     OR jsonb_typeof(src) IS DISTINCT FROM 'object' OR jsonb_typeof(argv) IS DISTINCT FROM 'array' THEN
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
    AND p_spec->'schema_version' = '1' AND p_spec->'capabilities' = '[]' AND p_spec->'pins' = '{}'
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
REVOKE ALL ON FUNCTION submit_task(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION submit_task(jsonb) TO exec_pool_submit;
GRANT SELECT ON task_summaries, attempts, events TO exec_pool_submit;

INSERT INTO schema_migrations (version) VALUES (2);
