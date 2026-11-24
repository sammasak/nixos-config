-- 0010's session_gc with the hand-back rule for final sessions too: a session is eligible only when its last turn's
-- branch is known to hold its tree, whether it is waiting or final, so a failed or cancelled one whose work was not
-- handed back whole is kept. Its columns are 0010's, which OR REPLACE requires. The runner role reads it too: a host
-- that reaches the queue over TCP (msi) removes its own trees by this list.
CREATE OR REPLACE VIEW session_gc AS
  SELECT task, state, changed_at, hosts, handed_back,
    handed_back IS TRUE AND ((state IN ('succeeded', 'failed', 'cancelled') AND changed_at < now() - interval '7 days')
      OR (state = 'waiting' AND idle)) AS eligible,
    state = 'waiting' AND idle AND handed_back IS NOT TRUE AS stale
  FROM (
    SELECT t.id AS task, a.status AS state, a.changed_at,
      coalesce((SELECT jsonb_agg(DISTINCT h ORDER BY h) FROM (
        SELECT e.host FROM events e WHERE e.attempt_id = a.id AND e.host IS NOT NULL
        UNION SELECT jsonb_array_elements_text(CASE WHEN jsonb_typeof(a.checkpoint->'hosts') = 'array'
          THEN a.checkpoint->'hosts' END)
      ) x (h)), '[]') AS hosts,
      (SELECT u.handed_back FROM turns u WHERE u.attempt_id = a.id AND u.lease_epoch = a.lease_epoch) AS handed_back,
      a.changed_at < now() - interval '14 days'
        AND NOT EXISTS (SELECT FROM inbox i WHERE i.task_id = t.id AND i.consumed_epoch IS NULL) AS idle
    FROM tasks t JOIN attempts a ON a.task_id = t.id WHERE t.session
  ) s;
GRANT SELECT ON session_gc TO exec_pool_runner;

-- narrows what 0010 lists: a binary at 9 or 10 reads it as before
INSERT INTO schema_migrations (version, floor) VALUES (11, 9);
