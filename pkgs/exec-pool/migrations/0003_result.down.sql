-- before 0001_queue.down.sql, which cannot drop attempts while results references it; a no-op below migration 3
DROP TABLE IF EXISTS results;
