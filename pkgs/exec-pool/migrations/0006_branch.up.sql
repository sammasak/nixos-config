-- The branch a task pushed, pool/<task id> (pkgs/exec-pool/src/agent.rs), when the repository showed it after the run:
-- how a submitter finds the code a task handed back. NULL: none pushed, or the runner could not tell.
ALTER TABLE results ADD COLUMN branch text CHECK (octet_length(branch) <= 255);
GRANT UPDATE (branch) ON results TO exec_pool_runner;

INSERT INTO schema_migrations (version) VALUES (6);
