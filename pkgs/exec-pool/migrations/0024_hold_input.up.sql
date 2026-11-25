-- A park whose input never reached the agent (queue.rs hold_input) holds that input unread until its error backoff's
-- continue is due, and past the backoff until a message comes (due_at infinity, handed with the next turn's input), so
-- the session is not queued again at once and counts as stalled. A function, not a column grant: the runner moves
-- only the rows its own turn was handed.
CREATE FUNCTION hold_input(p_task text, p_upto int8, p_secs int8) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF p_upto IS NULL OR NOT EXISTS (SELECT FROM tasks WHERE id = p_task AND session) THEN
    RAISE EXCEPTION 'hold_input: no session % or no upto', p_task USING ERRCODE = '22023';
  END IF;
  UPDATE inbox SET due_at = CASE WHEN p_secs IS NULL THEN 'infinity'::timestamptz
    ELSE now() + p_secs * interval '1 second' END
  WHERE task_id = p_task AND id <= p_upto AND consumed_epoch IS NULL AND (due_at IS NULL OR due_at <= now());
END $$;
REVOKE ALL ON FUNCTION hold_input(text, int8, int8) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION hold_input(text, int8, int8) TO exec_pool_runner;

-- additive: a binary at 9 to 23 never holds; it hands a held row once it is due, and one held past the backoff is
-- handed by the first binary at 24 to claim the session
INSERT INTO schema_migrations (version, floor) VALUES (24, 9);
