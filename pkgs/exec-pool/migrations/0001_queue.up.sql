-- The execution pool queue (#651). Forward-only in production: 0001_queue.down.sql drops everything, for a fresh
-- database or a rollback whose data the operator has exported first.
CREATE TABLE schema_migrations (
  version integer PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);

-- The task as submitted, prompt and paths included: the only table that holds them.
CREATE TABLE tasks (
  id text PRIMARY KEY CHECK (id <> ''),
  idempotency_key text NOT NULL UNIQUE CHECK (idempotency_key <> ''),
  spec jsonb NOT NULL,
  max_attempts integer NOT NULL CHECK (max_attempts >= 1),
  submitted_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE attempts (
  id text PRIMARY KEY,
  task_id text NOT NULL UNIQUE REFERENCES tasks (id),
  lease_epoch bigint NOT NULL DEFAULT 0 CHECK (lease_epoch >= 0),
  tries integer NOT NULL DEFAULT 0 CHECK (tries >= 0),
  status text NOT NULL DEFAULT 'queued' CHECK (status IN
    ('queued', 'leased', 'running', 'checkpointing', 'waiting', 'succeeded', 'failed', 'needs_review')),
  host text,
  slot text,
  pins jsonb NOT NULL DEFAULT '{}',
  lease_deadline timestamptz,
  checkpoint jsonb,
  changed_at timestamptz NOT NULL DEFAULT now(),
  -- the epoch a writer holds, checked and cleared by attempts_fence: never stored
  fence bigint,
  CHECK ((host IS NULL) = (slot IS NULL)),
  CHECK ((lease_deadline IS NOT NULL) = (status IN ('leased', 'running', 'checkpointing')))
);
CREATE INDEX attempts_queued ON attempts (changed_at, id) WHERE status = 'queued';
CREATE INDEX attempts_deadline ON attempts (lease_deadline) WHERE lease_deadline IS NOT NULL;
-- one live attempt per slot
CREATE UNIQUE INDEX attempts_slot_live ON attempts (host, slot) WHERE status IN ('leased', 'running', 'checkpointing');

-- The fence, in the database so a writer that skipped its own check is still refused: every update names the epoch
-- it was decided on in `fence`, the epoch moves by at most one, a lease starts only from queued, and a settled
-- attempt never changes again.
CREATE FUNCTION attempts_fence() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.fence IS DISTINCT FROM OLD.lease_epoch THEN
    RAISE EXCEPTION 'attempt %: write at epoch % but the attempt holds %', OLD.id, NEW.fence, OLD.lease_epoch
      USING ERRCODE = 'XP409';
  END IF;
  IF NEW.lease_epoch NOT IN (OLD.lease_epoch, OLD.lease_epoch + 1)
     OR (NEW.status = 'leased' AND NEW.lease_epoch <> OLD.lease_epoch AND OLD.status <> 'queued')
     OR OLD.status IN ('succeeded', 'failed') THEN
    RAISE EXCEPTION 'attempt %: % at epoch % may not become % at epoch %',
      OLD.id, OLD.status, OLD.lease_epoch, NEW.status, NEW.lease_epoch USING ERRCODE = 'XP409';
  END IF;
  NEW.fence := NULL;
  RETURN NEW;
END $$;
CREATE TRIGGER attempts_fence BEFORE UPDATE ON attempts FOR EACH ROW EXECUTE FUNCTION attempts_fence();

-- State history; no prompt, argv, path or session content, only ids, states and reason codes.
CREATE TABLE events (
  id bigserial PRIMARY KEY,
  at timestamptz NOT NULL DEFAULT now(),
  task_id text NOT NULL REFERENCES tasks (id),
  attempt_id text NOT NULL REFERENCES attempts (id),
  lease_epoch bigint NOT NULL,
  from_status text,
  to_status text NOT NULL,
  reason text NOT NULL,
  host text,
  slot text,
  in_state_ms bigint NOT NULL,
  since_submit_ms bigint NOT NULL
);

-- A receipt, linked to the settle event it arrived with.
CREATE TABLE receipts (
  event_id bigint PRIMARY KEY REFERENCES events (id),
  attempt_id text NOT NULL REFERENCES attempts (id),
  lease_epoch bigint NOT NULL,
  outcome text NOT NULL,
  effects jsonb NOT NULL
);

INSERT INTO schema_migrations (version) VALUES (1);
