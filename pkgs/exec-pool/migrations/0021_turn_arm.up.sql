-- The slot's declared Claude settings each turn ran under (its runner's EXEC_POOL_ARM), for comparing them by metric
-- label: variant is the compaction window in tokens or default, shunt on or off. NULL: a runner from before 21, or
-- one with no arm set.
ALTER TABLE turns
  ADD COLUMN variant text CHECK (variant ~ '^[a-z0-9]{1,16}$'),
  ADD COLUMN shunt text CHECK (shunt IN ('on', 'off'));

-- additive: a binary at 9 to 20 writes neither, so its turns read as unknown
INSERT INTO schema_migrations (version, floor) VALUES (21, 9);
