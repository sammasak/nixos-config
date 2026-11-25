-- Teardown only, before 0001_queue.down.sql, which cannot drop tasks while transcripts references it
DROP TRIGGER IF EXISTS transcripts_drop_final ON attempts;
DROP FUNCTION IF EXISTS transcripts_drop_final();
DROP TABLE IF EXISTS transcripts;
