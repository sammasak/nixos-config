-- A turn after a park for a host powering off is told so first (fn turn in queue.rs): the runner reads why its
-- attempt last parked. A reason is a fixed label, never content.
GRANT SELECT (reason) ON events TO exec_pool_runner;

-- additive: a binary at 9 to 12 neither reads nor needs it
INSERT INTO schema_migrations (version, floor) VALUES (13, 9);
