-- 0020's summaries for the work-done ledger (#806), columns appended as OR REPLACE allows, its grant kept: one-shot
-- agent tasks too (a `none` task's argv is its own command, never shown), each task's model (its argv's second item,
-- `default` when it named none; NULL for a `none` task) and whether it is a session. Cost sums as numeric, which
-- adds exactly in any order: a float8 sum varies in its last bit between reads. It is NULL with no turn reported, so
-- a one-shot task (its usage is never recorded) is unpriced, not free.
CREATE OR REPLACE VIEW session_summaries AS
  WITH spans AS (
    SELECT e.attempt_id, e.from_status AS state,
      CASE WHEN e.from_status = 'waiting' THEN coalesce((SELECT p.reason FROM events p
        WHERE p.attempt_id = e.attempt_id AND p.to_status = 'waiting' AND p.id < e.id ORDER BY p.id DESC LIMIT 1),
        'none') END AS why,
      e.in_state_ms AS ms
    FROM events e JOIN tasks t ON t.id = e.task_id WHERE (t.session OR t.spec->'command'->>'agent' <> 'none')
      AND e.from_status IS NOT NULL
    UNION ALL
    SELECT a.id, a.status,
      CASE WHEN a.status = 'waiting' THEN coalesce((SELECT p.reason FROM events p
        WHERE p.attempt_id = a.id AND p.to_status = 'waiting' ORDER BY p.id DESC LIMIT 1), 'none') END,
      (extract(epoch FROM now() - a.changed_at) * 1000)::bigint
    FROM attempts a JOIN tasks t ON t.id = a.task_id
    WHERE (t.session OR t.spec->'command'->>'agent' <> 'none') AND a.status NOT IN ('succeeded', 'failed', 'cancelled')
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
    CASE WHEN u.reported > 0 THEN u.cost_usd END AS cost_usd,
    (SELECT r.branch FROM results r WHERE r.attempt_id = a.id) AS branch,
    CASE WHEN t.spec->'command'->>'agent' <> 'none' THEN CASE WHEN jsonb_array_length(t.spec->'command'->'argv') = 2
      THEN t.spec->'command'->'argv'->>1 ELSE 'default' END END AS model,
    t.session
  FROM tasks t JOIN attempts a ON a.task_id = t.id
  LEFT JOIN times x ON x.attempt_id = a.id
  LEFT JOIN waits w ON w.attempt_id = a.id
  CROSS JOIN LATERAL (SELECT count(n.input_tokens) AS reported, coalesce(sum(n.input_tokens), 0)::bigint AS input_tokens,
      coalesce(sum(n.output_tokens), 0)::bigint AS output_tokens, coalesce(sum(n.cache_read_tokens), 0)::bigint AS cache_read_tokens,
      coalesce(sum(n.cache_creation_tokens), 0)::bigint AS cache_creation_tokens,
      coalesce(sum(n.cost_usd::numeric), 0)::float8 AS cost_usd
    FROM turns n WHERE n.attempt_id = a.id) u
  WHERE t.session OR t.spec->'command'->>'agent' <> 'none';

-- additive: a binary at 9 to 23 reads the columns it names and never these
INSERT INTO schema_migrations (version, floor) VALUES (24, 9);
