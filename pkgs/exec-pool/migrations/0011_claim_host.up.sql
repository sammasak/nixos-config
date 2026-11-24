-- The claim pins a session that ran but never parked to the host it ran on (Store::claim's RAN_ON): the runner reads
-- where its attempt's `running` events were.
GRANT SELECT (host) ON events TO exec_pool_runner;

-- additive: a binary at 9 or 10 neither reads nor needs it
INSERT INTO schema_migrations (version, floor) VALUES (11, 9);
