-- Where a session's time and money went, one row per session, for `exec-pool sessions` and the pool dashboard's
-- merged-sessions table (through the session report's journal lines, never a metric label). Ids, states, reason
-- codes, numbers and the repository only, no prompt. Time is from the event history: running is a lease's (leased,
-- running, checkpointing), waiting is split by the reason its turn parked (`settle` for a settle to waiting), queued
-- is waiting for a slot, review is needs_review; the state a session is still in counts up to now.
CREATE VIEW session_summaries AS
  WITH spans AS (
    SELECT e.attempt_id, e.from_status AS state,
      CASE WHEN e.from_status = 'waiting' THEN coalesce((SELECT p.reason FROM events p
        WHERE p.attempt_id = e.attempt_id AND p.to_status = 'waiting' AND p.id < e.id ORDER BY p.id DESC LIMIT 1),
        'none') END AS why,
      e.in_state_ms AS ms
    FROM events e JOIN tasks t ON t.id = e.task_id WHERE t.session AND e.from_status IS NOT NULL
    UNION ALL
    SELECT a.id, a.status,
      CASE WHEN a.status = 'waiting' THEN coalesce((SELECT p.reason FROM events p
        WHERE p.attempt_id = a.id AND p.to_status = 'waiting' ORDER BY p.id DESC LIMIT 1), 'none') END,
      (extract(epoch FROM now() - a.changed_at) * 1000)::bigint
    FROM attempts a JOIN tasks t ON t.id = a.task_id
    WHERE t.session AND a.status NOT IN ('succeeded', 'failed', 'cancelled')
  ),
  times AS (
    SELECT attempt_id,
      coalesce(sum(ms) FILTER (WHERE state IN ('leased', 'running', 'checkpointing')), 0) AS running_ms,
      coalesce(sum(ms) FILTER (WHERE state = 'waiting'), 0) AS waiting_ms,
      coalesce(sum(ms) FILTER (WHERE state = 'queued'), 0) AS queued_ms,
      coalesce(sum(ms) FILTER (WHERE state = 'needs_review'), 0) AS review_ms
    FROM spans GROUP BY attempt_id
  ),
  waits AS (
    SELECT attempt_id, jsonb_object_agg(why, (ms / 1000.0)::float8) AS by_reason
    FROM (SELECT attempt_id, why, sum(ms) AS ms FROM spans WHERE state = 'waiting' GROUP BY 1, 2) w
    GROUP BY attempt_id
  )
  SELECT t.id AS task, a.id AS attempt, a.status AS state, t.spec->'command'->>'agent' AS agent,
    t.spec->'source'->>'repo' AS repo, t.submitted_at, a.changed_at,
    (SELECT h.host FROM events h WHERE h.attempt_id = a.id AND h.host IS NOT NULL ORDER BY h.id DESC LIMIT 1)
      AS last_host,
    (SELECT count(*) FROM events e WHERE e.attempt_id = a.id AND e.to_status = 'running') AS turns,
    extract(epoch FROM (CASE WHEN a.status IN ('succeeded', 'failed', 'cancelled') THEN a.changed_at ELSE now() END)
      - t.submitted_at)::float8 AS wall_seconds,
    (coalesce(x.running_ms, 0) / 1000.0)::float8 AS running_seconds,
    (coalesce(x.waiting_ms, 0) / 1000.0)::float8 AS waiting_seconds,
    coalesce(w.by_reason, '{}') AS waiting_by_reason,
    (coalesce(x.queued_ms, 0) / 1000.0)::float8 AS queued_seconds,
    (coalesce(x.review_ms, 0) / 1000.0)::float8 AS review_seconds,
    u.reported AS turns_reported, u.input_tokens, u.output_tokens, u.cache_read_tokens, u.cache_creation_tokens,
    u.cost_usd,
    (SELECT r.branch FROM results r WHERE r.attempt_id = a.id) AS branch
  FROM tasks t JOIN attempts a ON a.task_id = t.id
  LEFT JOIN times x ON x.attempt_id = a.id
  LEFT JOIN waits w ON w.attempt_id = a.id
  CROSS JOIN LATERAL (SELECT count(n.input_tokens) AS reported, coalesce(sum(n.input_tokens), 0)::bigint AS input_tokens,
      coalesce(sum(n.output_tokens), 0)::bigint AS output_tokens, coalesce(sum(n.cache_read_tokens), 0)::bigint AS cache_read_tokens,
      coalesce(sum(n.cache_creation_tokens), 0)::bigint AS cache_creation_tokens,
      coalesce(sum(n.cost_usd), 0)::float8 AS cost_usd
    FROM turns n WHERE n.attempt_id = a.id) u
  WHERE t.session;
GRANT SELECT ON session_summaries TO exec_pool_submit;

-- additive: a binary at 9 to 19 neither reads nor needs it
INSERT INTO schema_migrations (version, floor) VALUES (20, 9);
