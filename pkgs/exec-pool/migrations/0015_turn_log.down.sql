-- Teardown only, before 0001_queue.down.sql, which cannot drop attempts while turn_logs references it
DROP TABLE IF EXISTS turn_logs;
