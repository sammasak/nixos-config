-- A turn whose pane or prompt never reached the agent (runner::parks_undelivered): its park marks nothing read, and a
-- first turn stays first, so the next turn is handed the same input, the task's prompt included.
ALTER TABLE turns ADD COLUMN delivered boolean NOT NULL DEFAULT true;

-- additive: a binary at 9 to 17 writes none, so every turn it parks counts as delivered
INSERT INTO schema_migrations (version, floor) VALUES (18, 9);
