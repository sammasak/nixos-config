-- A task's priority at claim: higher first, and a queued attempt gains one step per 10 minutes it waits (Store::claim's
-- ORDER BY), so a low one is not starved for ever. No preemption: a running task keeps its slot. The bound keeps the
-- wait a high one can impose bounded too: 100 steps, under 17 hours.
ALTER TABLE tasks ADD COLUMN priority integer NOT NULL DEFAULT 0 CHECK (priority BETWEEN -100 AND 100);

-- submit_task and start_session with a priority. The 1-argument ones stay, priority 0, for a binary before 16; the same
-- key again returns the task with the priority it was first given.
CREATE FUNCTION submit_task(p_spec jsonb, p_priority integer, OUT o_task text, OUT o_attempt text,
  OUT o_duplicate boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF p_priority IS NULL OR p_priority NOT BETWEEN -100 AND 100 THEN
    RAISE EXCEPTION 'submit_task: priority % is not between -100 and 100', p_priority USING ERRCODE = '22023';
  END IF;
  SELECT s.o_task, s.o_attempt, s.o_duplicate INTO o_task, o_attempt, o_duplicate FROM submit_task(p_spec) s;
  IF NOT o_duplicate THEN
    UPDATE tasks SET priority = p_priority WHERE id = o_task;
  END IF;
END $$;
REVOKE ALL ON FUNCTION submit_task(jsonb, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION submit_task(jsonb, integer) TO exec_pool_submit;

CREATE FUNCTION start_session(p_spec jsonb, p_priority integer, OUT o_task text, OUT o_attempt text,
  OUT o_duplicate boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF p_priority IS NULL OR p_priority NOT BETWEEN -100 AND 100 THEN
    RAISE EXCEPTION 'start_session: priority % is not between -100 and 100', p_priority USING ERRCODE = '22023';
  END IF;
  SELECT s.o_task, s.o_attempt, s.o_duplicate INTO o_task, o_attempt, o_duplicate FROM start_session(p_spec) s;
  IF NOT o_duplicate THEN
    UPDATE tasks SET priority = p_priority WHERE id = o_task;
  END IF;
END $$;
REVOKE ALL ON FUNCTION start_session(jsonb, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION start_session(jsonb, integer) TO exec_pool_submit;

-- additive: a binary at 9 to 15 claims by age alone and submits at priority 0
INSERT INTO schema_migrations (version, floor) VALUES (16, 9);
