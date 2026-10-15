BEGIN;

-- First Phase 08 slice: tenant job metadata isolation and intent fingerprint.
-- This migration does not create workers, call providers, or touch production.
ALTER TABLE hcp.jobs
  ADD COLUMN intent_fingerprint text
  CHECK (intent_fingerprint IS NULL OR intent_fingerprint ~ '^[0-9a-f]{64}$');

CREATE INDEX jobs_tenant_queue_idx
  ON hcp.jobs(tenant_id, status, created_at)
  WHERE tenant_id IS NOT NULL;

-- Fail closed even when hcp.scope is set to 'platform' by a normal DB role.
-- Trusted worker access needs a separately reviewed DB identity and contract.
ALTER TABLE hcp.jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE hcp.jobs FORCE ROW LEVEL SECURITY;
CREATE POLICY jobs_tenant_scope_policy ON hcp.jobs
FOR ALL
USING (
  hcp.current_request_scope() = 'tenant'
  AND tenant_id IS NOT NULL
  AND tenant_id = hcp.current_tenant_id()
)
WITH CHECK (
  hcp.current_request_scope() = 'tenant'
  AND tenant_id IS NOT NULL
  AND tenant_id = hcp.current_tenant_id()
);

-- Child rows inherit visibility from their parent job. Independent resource
-- identifiers must never bypass the tenant boundary.
ALTER TABLE hcp.job_steps ENABLE ROW LEVEL SECURITY;
ALTER TABLE hcp.job_steps FORCE ROW LEVEL SECURITY;
CREATE POLICY job_steps_tenant_scope_policy ON hcp.job_steps
FOR ALL
USING (EXISTS (
  SELECT 1 FROM hcp.jobs j WHERE j.id = job_steps.job_id
))
WITH CHECK (EXISTS (
  SELECT 1 FROM hcp.jobs j WHERE j.id = job_steps.job_id
));

ALTER TABLE hcp.job_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE hcp.job_events FORCE ROW LEVEL SECURITY;
CREATE POLICY job_events_tenant_scope_policy ON hcp.job_events
FOR ALL
USING (EXISTS (
  SELECT 1 FROM hcp.jobs j WHERE j.id = job_events.job_id
))
WITH CHECK (EXISTS (
  SELECT 1 FROM hcp.jobs j WHERE j.id = job_events.job_id
));

ALTER TABLE hcp.resource_locks ENABLE ROW LEVEL SECURITY;
ALTER TABLE hcp.resource_locks FORCE ROW LEVEL SECURITY;
CREATE POLICY resource_locks_tenant_scope_policy ON hcp.resource_locks
FOR ALL
USING (EXISTS (
  SELECT 1 FROM hcp.jobs j WHERE j.id = resource_locks.job_id
))
WITH CHECK (EXISTS (
  SELECT 1 FROM hcp.jobs j WHERE j.id = resource_locks.job_id
));

INSERT INTO hcp.schema_migrations(version, name)
VALUES (8, 'job_orchestrator_security');

COMMIT;
