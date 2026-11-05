BEGIN;

DELETE FROM hcp.schema_migrations
WHERE version = 8 AND name = 'job_orchestrator_security';

DROP POLICY IF EXISTS resource_locks_tenant_scope_policy ON hcp.resource_locks;
ALTER TABLE hcp.resource_locks NO FORCE ROW LEVEL SECURITY;
ALTER TABLE hcp.resource_locks DISABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS job_events_tenant_scope_policy ON hcp.job_events;
ALTER TABLE hcp.job_events NO FORCE ROW LEVEL SECURITY;
ALTER TABLE hcp.job_events DISABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS job_steps_tenant_scope_policy ON hcp.job_steps;
ALTER TABLE hcp.job_steps NO FORCE ROW LEVEL SECURITY;
ALTER TABLE hcp.job_steps DISABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS jobs_tenant_scope_policy ON hcp.jobs;
ALTER TABLE hcp.jobs NO FORCE ROW LEVEL SECURITY;
ALTER TABLE hcp.jobs DISABLE ROW LEVEL SECURITY;

DROP INDEX IF EXISTS hcp.jobs_tenant_queue_idx;
ALTER TABLE hcp.jobs DROP COLUMN IF EXISTS intent_fingerprint;

COMMIT;
