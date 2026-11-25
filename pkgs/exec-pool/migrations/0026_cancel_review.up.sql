-- cancel_task also settles a needs_review attempt as cancelled, so a submitter that judged the result itself (the
-- local-model lane, scripts/local-lane.py) leaves nothing waiting on an operator. 0005's otherwise.
CREATE OR REPLACE FUNCTION cancel_task(p_id text, OUT o_attempt text, OUT o_status text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  a attempts%ROWTYPE;
  submitted timestamptz;
BEGIN
  SELECT x.* INTO a FROM attempts x JOIN tasks t ON t.id = x.task_id
    WHERE (t.id = p_id OR x.id = p_id) AND t.submitter = session_user ORDER BY t.id = p_id DESC LIMIT 1
    FOR UPDATE OF x;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'cancel_task: no task % of yours', p_id USING ERRCODE = 'P0002';
  END IF;
  o_attempt := a.id;
  o_status := a.status;
  IF a.status IN ('queued', 'waiting', 'needs_review') THEN
    SELECT t.submitted_at INTO submitted FROM tasks t WHERE t.id = a.task_id;
    UPDATE attempts SET status = 'cancelled', fence = a.lease_epoch, changed_at = now() WHERE id = a.id;
    INSERT INTO events (task_id, attempt_id, lease_epoch, from_status, to_status, reason, in_state_ms, since_submit_ms)
      VALUES (a.task_id, a.id, a.lease_epoch, a.status, 'cancelled', 'cancelled',
        (extract(epoch FROM now() - a.changed_at) * 1000)::bigint,
        (extract(epoch FROM now() - submitted) * 1000)::bigint);
    o_status := 'cancelled';
  ELSIF a.status IN ('leased', 'running', 'checkpointing') AND NOT a.cancel_requested THEN
    UPDATE attempts SET cancel_requested = true, fence = a.lease_epoch WHERE id = a.id;
  END IF;
END $$;
REVOKE ALL ON FUNCTION cancel_task(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cancel_task(text) TO exec_pool_submit;

-- additive: a binary at 9 to 25 reads cancelled as settled and never calls this differently
INSERT INTO schema_migrations (version, floor) VALUES (26, 9);
