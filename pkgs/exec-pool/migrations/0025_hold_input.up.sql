-- A park whose input never reached the agent (queue.rs hold_input) holds what its claim handed over, still unread,
-- until its error backoff's continue is due, and past the backoff (due_at infinity), either until a message comes,
-- whose insert makes them due again, so the session is not queued again at once and counts as stalled. A function,
-- not a column grant: the runner moves only the rows its own turn was handed.
CREATE FUNCTION hold_input(p_task text, p_attempt text, p_epoch int8, p_upto int8, p_secs int8) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF p_upto IS NULL OR NOT EXISTS (SELECT FROM attempts a JOIN tasks t ON t.id = a.task_id
    WHERE a.id = p_attempt AND t.id = p_task AND t.session) THEN
    RAISE EXCEPTION 'hold_input: no session % with attempt % or no upto', p_task, p_attempt USING ERRCODE = '22023';
  END IF;
  UPDATE inbox SET due_at = CASE WHEN p_secs IS NULL THEN 'infinity'::timestamptz
    ELSE now() + p_secs * interval '1 second' END
  WHERE task_id = p_task AND id <= p_upto AND consumed_epoch IS NULL
    AND (due_at IS NULL OR due_at <= (SELECT max(e.at) FROM events e
    WHERE e.attempt_id = p_attempt AND e.lease_epoch = p_epoch AND e.to_status = 'leased'));
END $$;
REVOKE ALL ON FUNCTION hold_input(text, text, int8, int8, int8) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION hold_input(text, text, int8, int8, int8) TO exec_pool_runner;

-- a new message releases every held row before it (only a hold gives a message a due_at), in the queue, not the
-- runner: whatever binary claims the turn after reads them as due, in order
CREATE FUNCTION release_held_input() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  UPDATE inbox SET due_at = NULL
    WHERE task_id = NEW.task_id AND consumed_epoch IS NULL AND id < NEW.id
    AND (due_at = 'infinity'::timestamptz OR (kind = 'message' AND due_at IS NOT NULL));
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION release_held_input() FROM PUBLIC;
CREATE TRIGGER inbox_release_held_input AFTER INSERT ON inbox
  FOR EACH ROW WHEN (NEW.kind = 'message') EXECUTE FUNCTION release_held_input();

-- additive: a binary at 9 to 24 never holds, reads a held row as not yet due, and a message releases one held past
-- the backoff for it as for any binary
INSERT INTO schema_migrations (version, floor) VALUES (25, 9);
