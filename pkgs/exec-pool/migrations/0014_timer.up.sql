-- Timers: an inbox row of kind timer is delivered once due_at has passed. A waiting session with a due row is queued
-- by Store::reconcile (or at its park, when the row is already due); one in needs_review stays there until a message
-- or a resolve, as a timer is not the owner's decision that it may go on.

-- p_task as send_message takes it. The row is only inserted: the session is queued once it is due.
CREATE FUNCTION send_timer(p_task text, p_body text, p_due timestamptz, OUT o_attempt text, OUT o_status text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  a attempts%ROWTYPE;
BEGIN
  SELECT x.* INTO a FROM attempts x JOIN tasks y ON y.id = x.task_id
    WHERE (y.id = p_task OR x.id = p_task) AND y.submitter = session_user ORDER BY y.id = p_task DESC LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'send_timer: no task % of yours', p_task USING ERRCODE = 'P0002';
  END IF;
  IF NOT (SELECT t.session FROM tasks t WHERE t.id = a.task_id) THEN
    RAISE EXCEPTION 'send_timer: task % is not a session', a.task_id USING ERRCODE = '22023';
  END IF;
  IF p_body IS NULL OR p_body = '' OR p_due IS NULL THEN
    RAISE EXCEPTION 'send_timer: a timer needs a message and a time' USING ERRCODE = '22023';
  END IF;
  IF a.status IN ('succeeded', 'failed', 'cancelled') THEN
    RAISE EXCEPTION 'send_timer: task % is %', a.task_id, a.status USING ERRCODE = '55000';
  END IF;
  INSERT INTO inbox (task_id, kind, body, due_at) VALUES (a.task_id, 'timer', p_body, p_due);
  o_attempt := a.id;
  o_status := a.status;
END $$;
REVOKE ALL ON FUNCTION send_timer(text, text, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION send_timer(text, text, timestamptz) TO exec_pool_submit;

-- The runner's half: a park hands in the timer its turn asked for (pool-wait), its note the body. A function, not a
-- column grant, so the runner still writes no message.
CREATE FUNCTION wake_at(p_task text, p_due timestamptz, p_note text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF p_due IS NULL OR NOT EXISTS (SELECT FROM tasks WHERE id = p_task AND session) THEN
    RAISE EXCEPTION 'wake_at: no session % or no time', p_task USING ERRCODE = '22023';
  END IF;
  INSERT INTO inbox (task_id, kind, body, due_at) VALUES (p_task, 'timer', p_note, p_due);
END $$;
REVOKE ALL ON FUNCTION wake_at(text, timestamptz, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION wake_at(text, timestamptz, text) TO exec_pool_runner;

-- additive: a binary at 9 to 13 never wakes a session by its timer, and nothing it writes needs one
INSERT INTO schema_migrations (version, floor) VALUES (14, 9);
