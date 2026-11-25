-- 0009's view with the priority appended, which OR REPLACE allows; its grant stays. exec-pool status and list read it.
CREATE OR REPLACE VIEW task_summaries AS
  SELECT id, submitted_at, spec->'command'->'agent' AS agent, spec->'source'->'repo' AS repo,
    spec->'source'->'rev' AS rev, spec->'command'->'workdir' AS workdir, session, priority
  FROM tasks;

-- additive: a binary at 9 to 21 reads the columns it names and never this one
INSERT INTO schema_migrations (version, floor) VALUES (22, 9);
