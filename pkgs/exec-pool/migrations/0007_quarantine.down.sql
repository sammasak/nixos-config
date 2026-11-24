-- Teardown only, before 0001_queue.down.sql drops schema_migrations and its floor; a no-op below migration 7
DROP TABLE IF EXISTS quarantined_slots;
