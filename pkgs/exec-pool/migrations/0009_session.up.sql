-- Sessions. A session task's every lease is one turn, and every turn ends parked in waiting (Store::park); a row in
-- its inbox wakes it. The inbox holds what its owner sent, prompts as much as tasks.spec: the runner reads it, the
-- submitter only writes it, through send_message. A one-shot task (session false) is queued and run as before.
-- floor: pool/rollback-safe's schema_migrations.floor is not on main yet; once it is, this records floor 9, as a
-- binary without sessions would run a session as a one-shot.
ALTER TABLE tasks ADD COLUMN session boolean NOT NULL DEFAULT false,
  ADD COLUMN session_uuid uuid NOT NULL DEFAULT gen_random_uuid();

CREATE TABLE inbox (
  id bigserial PRIMARY KEY,
  task_id text NOT NULL REFERENCES tasks (id),
  kind text NOT NULL CHECK (kind IN ('message', 'timer', 'continue')),
  body text CHECK (kind <> 'message' OR (body IS NOT NULL AND body <> '')),
  -- a row is delivered once due; NULL is due at once
  due_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  -- the epoch of the turn that parked having been handed it; NULL while unread
  consumed_epoch bigint
);
CREATE INDEX inbox_unread ON inbox (task_id, id) WHERE consumed_epoch IS NULL;

-- 0002's view with the session flag appended, which OR REPLACE allows; its grant stays
CREATE OR REPLACE VIEW task_summaries AS
  SELECT id, submitted_at, spec->'command'->'agent' AS agent, spec->'source'->'repo' AS repo,
    spec->'source'->'rev' AS rev, spec->'command'->'workdir' AS workdir, session
  FROM tasks;

-- submit_task's task, claude only, as a session. The same key again returns the session; a key that already names a
-- one-shot task is a conflict.
CREATE FUNCTION start_session(p_spec jsonb, OUT o_task text, OUT o_attempt text, OUT o_duplicate boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF jsonb_typeof(p_spec) IS DISTINCT FROM 'object' OR p_spec->'command'->'agent' IS DISTINCT FROM '"claude"' THEN
    RAISE EXCEPTION 'start_session: a session is a claude task' USING ERRCODE = '22023';
  END IF;
  SELECT s.o_task, s.o_attempt, s.o_duplicate INTO o_task, o_attempt, o_duplicate FROM submit_task(p_spec) s;
  IF NOT o_duplicate THEN
    UPDATE tasks SET session = true WHERE id = o_task;
  ELSIF NOT (SELECT t.session FROM tasks t WHERE t.id = o_task) THEN
    RAISE EXCEPTION 'idempotency key % already names a one-shot task', p_spec->>'idempotency_key'
      USING ERRCODE = '23505';
  END IF;
END $$;
REVOKE ALL ON FUNCTION start_session(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION start_session(jsonb) TO exec_pool_submit;

-- p_task is a session's id or its attempt's, the caller's own. The message is delivered at the session's next turn:
-- a waiting session is queued for it; one in needs_review is queued with its try given back (Resolution::Resume: the
-- owner's decision that it may go on, the only way out of review but an operator's resolve); a queued or live one
-- takes it when its current turn parks. A settled session takes none. One in review its owner asked to cancel is
-- cancelled instead, as queue.rs `write` cancels a marked attempt that goes back to the queue.
CREATE FUNCTION send_message(p_task text, p_body text, OUT o_attempt text, OUT o_status text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  a attempts%ROWTYPE;
  t tasks%ROWTYPE;
BEGIN
  SELECT x.* INTO a FROM attempts x JOIN tasks y ON y.id = x.task_id
    WHERE (y.id = p_task OR x.id = p_task) AND y.submitter = session_user ORDER BY y.id = p_task DESC LIMIT 1
    FOR UPDATE OF x;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'send_message: no task % of yours', p_task USING ERRCODE = 'P0002';
  END IF;
  SELECT y.* INTO t FROM tasks y WHERE y.id = a.task_id;
  IF NOT t.session THEN
    RAISE EXCEPTION 'send_message: task % is not a session', t.id USING ERRCODE = '22023';
  END IF;
  IF p_body IS NULL OR p_body = '' THEN
    RAISE EXCEPTION 'send_message: an empty message' USING ERRCODE = '22023';
  END IF;
  IF a.status IN ('succeeded', 'failed', 'cancelled') THEN
    RAISE EXCEPTION 'send_message: task % is %', t.id, a.status USING ERRCODE = '55000';
  END IF;
  INSERT INTO inbox (task_id, kind, body) VALUES (a.task_id, 'message', p_body);
  o_attempt := a.id;
  o_status := a.status;
  IF a.status IN ('waiting', 'needs_review') THEN
    o_status := CASE WHEN a.cancel_requested THEN 'cancelled' ELSE 'queued' END;
    UPDATE attempts SET status = o_status, host = NULL, slot = NULL, fence = a.lease_epoch, changed_at = now(),
      tries = CASE WHEN a.status = 'needs_review' THEN greatest(a.tries - 1, 0) ELSE a.tries END
      WHERE id = a.id;
    INSERT INTO events (task_id, attempt_id, lease_epoch, from_status, to_status, reason, in_state_ms, since_submit_ms)
      VALUES (a.task_id, a.id, a.lease_epoch, a.status, o_status,
        CASE WHEN a.cancel_requested THEN 'cancelled' ELSE 'message' END,
        (extract(epoch FROM now() - a.changed_at) * 1000)::bigint,
        (extract(epoch FROM now() - t.submitted_at) * 1000)::bigint);
  END IF;
END $$;
REVOKE ALL ON FUNCTION send_message(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION send_message(text, text) TO exec_pool_submit;

-- a claim reads the inbox and whether a turn ever started; a park marks read what was due at its lease and appends a
-- continue, which carries no body: a runner writes no message
GRANT SELECT ON inbox TO exec_pool_runner;
GRANT INSERT (task_id, kind) ON inbox TO exec_pool_runner;
GRANT UPDATE (consumed_epoch) ON inbox TO exec_pool_runner;
GRANT USAGE ON SEQUENCE inbox_id_seq TO exec_pool_runner;
GRANT SELECT (attempt_id, lease_epoch, to_status, at) ON events TO exec_pool_runner;

INSERT INTO schema_migrations (version) VALUES (9);
