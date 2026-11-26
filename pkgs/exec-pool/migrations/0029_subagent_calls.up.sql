-- The subagents a session turn's agent called, read from its transcript (pane::verdict): on results the bounded list
-- of each call's description and subagent type (no prompt, no output) and how many there were, on turns the count
-- alone for the metrics. NULL: the runner read no transcript (a one-shot or headless run), or a runner from before 29;
-- such a runner's later turn of a session leaves the results columns as the turn before it set them.
ALTER TABLE results
  ADD COLUMN subagent_calls jsonb CHECK (jsonb_typeof(subagent_calls) = 'array'),
  ADD COLUMN subagent_call_count integer CHECK (subagent_call_count >= 0);
GRANT UPDATE (subagent_calls, subagent_call_count) ON results TO exec_pool_runner;
ALTER TABLE turns ADD COLUMN subagent_calls integer CHECK (subagent_calls >= 0);
GRANT UPDATE (subagent_calls) ON turns TO exec_pool_runner;

-- additive: a binary at 9 to 28 writes none of them and reads the columns it names
INSERT INTO schema_migrations (version, floor) VALUES (29, 9);
