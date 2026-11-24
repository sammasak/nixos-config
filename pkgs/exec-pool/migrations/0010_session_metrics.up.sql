-- What the sessions' metrics and their garbage collection read beyond the event history. A park (Store::park) writes
-- one turns row per turn: the tokens and cost the agent reported, and whether the branch it handed back holds
-- everything its tree had. Numbers and a flag only, no content.
CREATE TABLE turns (
  attempt_id text NOT NULL REFERENCES attempts (id),
  lease_epoch bigint NOT NULL CHECK (lease_epoch >= 0),
  -- NULL: the agent reported none
  input_tokens bigint CHECK (input_tokens >= 0),
  output_tokens bigint CHECK (output_tokens >= 0),
  cache_read_tokens bigint CHECK (cache_read_tokens >= 0),
  cache_creation_tokens bigint CHECK (cache_creation_tokens >= 0),
  cost_usd double precision CHECK (cost_usd >= 0),
  -- NULL: the runner could not tell, so the tree may hold unpushed work
  handed_back boolean,
  parked_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (attempt_id, lease_epoch)
);
GRANT INSERT ON turns TO exec_pool_runner;

-- Which sessions' trees may be removed, decided here and never by a file's age, as a parked tree can hold unpushed
-- work. Eligible: final for 7 days; or waiting, with no unread inbox row, unchanged for 14 days, and its last turn's
-- branch known to hold its tree. Stale: waiting that long without that knowledge, kept and counted. needs_review is
-- never either. Only the current epoch's turns row counts: a session left waiting another way (a settle, a runner
-- from before 10) has none, so it is not known. hosts: every host a turn ran on or its checkpoint names.
CREATE VIEW session_gc AS
  SELECT task, state, changed_at, hosts, handed_back,
    (state IN ('succeeded', 'failed', 'cancelled') AND changed_at < now() - interval '7 days')
      OR (state = 'waiting' AND idle AND handed_back IS TRUE) AS eligible,
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
GRANT SELECT ON session_gc TO exec_pool_submit;

-- additive: a binary at 9 neither reads nor needs these
INSERT INTO schema_migrations (version, floor) VALUES (10, 9);
