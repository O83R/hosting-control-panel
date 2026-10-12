BEGIN;

ALTER TABLE hcp.jobs
  ADD COLUMN version bigint NOT NULL DEFAULT 1 CHECK (version > 0);

CREATE UNIQUE INDEX jobs_global_idempotency_key_uq
  ON hcp.jobs(idempotency_key)
  WHERE tenant_id IS NULL AND idempotency_key IS NOT NULL;

CREATE OR REPLACE FUNCTION hcp.job_status_transition_allowed(from_status text, to_status text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN from_status = 'queued' AND to_status IN ('running', 'cancelled') THEN true
    WHEN from_status = 'running' AND to_status IN ('succeeded', 'failed', 'cancelled') THEN true
    ELSE false
  END;
$$;

CREATE OR REPLACE FUNCTION hcp.enforce_job_status_transition()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;

  IF NOT hcp.job_status_transition_allowed(OLD.status, NEW.status) THEN
    RAISE EXCEPTION 'invalid job status transition: % -> %', OLD.status, NEW.status
      USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.status = 'running' AND NEW.started_at IS NULL THEN
    NEW.started_at := now();
  END IF;

  IF NEW.status IN ('succeeded', 'failed', 'cancelled') AND NEW.completed_at IS NULL THEN
    NEW.completed_at := now();
  END IF;

  NEW.version := OLD.version + 1;
  RETURN NEW;
END;
$$;

CREATE TRIGGER jobs_enforce_status_transition
BEFORE UPDATE OF status ON hcp.jobs
FOR EACH ROW
EXECUTE FUNCTION hcp.enforce_job_status_transition();

ALTER TABLE hcp.jobs
  ADD CONSTRAINT jobs_state_timestamps_ck
  CHECK (
    (status = 'queued' AND started_at IS NULL AND completed_at IS NULL)
    OR (status = 'running' AND started_at IS NOT NULL AND completed_at IS NULL)
    OR (status IN ('succeeded', 'failed', 'cancelled') AND completed_at IS NOT NULL)
  );

INSERT INTO hcp.schema_migrations(version, name)
VALUES (2, 'job_state_contract');

COMMIT;
