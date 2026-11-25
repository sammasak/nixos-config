-- A park after a turn that ended in a memory kill (queue.rs MEMORY_KILLED) hands in its continue's body, what the
-- kernel killed, which the next turn is told. A function, not a column grant, so the runner still writes no message.
CREATE FUNCTION continue_after(p_task text, p_secs int8, p_body text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF p_secs IS NULL OR p_body IS NULL OR NOT EXISTS (SELECT FROM tasks WHERE id = p_task AND session) THEN
    RAISE EXCEPTION 'continue_after: no session % or no delay or body', p_task USING ERRCODE = '22023';
  END IF;
  INSERT INTO inbox (task_id, kind, body, due_at) VALUES (p_task, 'continue', p_body, now() + p_secs * interval '1 second');
END $$;
REVOKE ALL ON FUNCTION continue_after(text, int8, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION continue_after(text, int8, text) TO exec_pool_runner;

-- additive: a binary at 9 to 22 never calls it, and delivers a continue's body as it would a message's
INSERT INTO schema_migrations (version, floor) VALUES (23, 9);
