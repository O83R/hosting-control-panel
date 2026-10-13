BEGIN;

DELETE FROM hcp.schema_migrations
WHERE version = 2 AND name = 'job_state_contract';

DROP TRIGGER IF EXISTS jobs_enforce_status_transition ON hcp.jobs;
DROP FUNCTION IF EXISTS hcp.enforce_job_status_transition();
DROP FUNCTION IF EXISTS hcp.job_status_transition_allowed(text, text);

DROP INDEX IF EXISTS hcp.jobs_global_idempotency_key_uq;

ALTER TABLE hcp.jobs
  DROP CONSTRAINT IF EXISTS jobs_state_timestamps_ck,
  DROP COLUMN IF EXISTS version;

COMMIT;
