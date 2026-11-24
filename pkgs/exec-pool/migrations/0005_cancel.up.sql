-- Cancel (#652). A task records the role that queued it, and cancel_task lets that role, the submitter included, call
-- off its own: a queued or waiting attempt becomes cancelled at once; a live one is marked, and its runner, which
-- reads the mark with every heartbeat, stops the run and settles it as cancelled. A needs_review or settled attempt is
-- left as it is. A runner that died stops heartbeating, so its lease still expires to needs_review.
ALTER TABLE attempts DROP CONSTRAINT attempts_status_check, ADD CONSTRAINT attempts_status_check CHECK (status IN
  ('queued', 'leased', 'running', 'checkpointing', 'waiting', 'succeeded', 'failed', 'needs_review', 'cancelled'));
ALTER TABLE attempts ADD COLUMN cancel_requested boolean NOT NULL DEFAULT false;
-- NULL for a task queued before this migration: no role may cancel it
ALTER TABLE tasks ADD COLUMN submitter text;

-- the login, not the definer: submit_task runs as the queue's owner
CREATE FUNCTION tasks_submitter() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.submitter := session_user;
  RETURN NEW;
END $$;
CREATE TRIGGER tasks_submitter BEFORE INSERT ON tasks FOR EACH ROW EXECUTE FUNCTION tasks_submitter();

-- 0001's fence, with cancelled as settled as succeeded and failed
CREATE OR REPLACE FUNCTION attempts_fence() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.fence IS DISTINCT FROM OLD.lease_epoch THEN
    RAISE EXCEPTION 'attempt %: write at epoch % but the attempt holds %', OLD.id, NEW.fence, OLD.lease_epoch
      USING ERRCODE = 'XP409';
  END IF;
  IF NEW.lease_epoch NOT IN (OLD.lease_epoch, OLD.lease_epoch + 1)
     OR (NEW.status = 'leased' AND NEW.lease_epoch <> OLD.lease_epoch AND OLD.status <> 'queued')
     OR OLD.status IN ('succeeded', 'failed', 'cancelled') THEN
    RAISE EXCEPTION 'attempt %: % at epoch % may not become % at epoch %',
      OLD.id, OLD.status, OLD.lease_epoch, NEW.status, NEW.lease_epoch USING ERRCODE = 'XP409';
  END IF;
  NEW.fence := NULL;
  RETURN NEW;
END $$;

-- p_id is a task's id or its attempt's. The attempt and its status after the call: cancelled, a live status (its runner
-- stops it within a heartbeat), or what it already was.
CREATE FUNCTION cancel_task(p_id text, OUT o_attempt text, OUT o_status text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  a attempts%ROWTYPE;
  submitted timestamptz;
BEGIN
  SELECT x.* INTO a FROM attempts x JOIN tasks t ON t.id = x.task_id
    WHERE (t.id = p_id OR x.id = p_id) AND t.submitter = session_user FOR UPDATE OF x;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'cancel_task: no task % of yours', p_id USING ERRCODE = 'P0002';
  END IF;
  o_attempt := a.id;
  o_status := a.status;
  IF a.status IN ('queued', 'waiting') THEN
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

INSERT INTO schema_migrations (version) VALUES (5);
