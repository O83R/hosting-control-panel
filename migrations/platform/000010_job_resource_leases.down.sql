BEGIN;

DROP FUNCTION IF EXISTS hcp.reconcile_expired_tenant_ping_lease(uuid,bigint);
DROP FUNCTION IF EXISTS hcp.release_tenant_ping_lease(uuid,bigint);
DROP FUNCTION IF EXISTS hcp.renew_tenant_ping_lease(uuid,bigint,integer);
DROP FUNCTION IF EXISTS hcp.claim_tenant_ping_lease(uuid,integer);

ALTER TABLE hcp.resource_locks
  DROP CONSTRAINT resource_locks_job_id_fkey;
ALTER TABLE hcp.resource_locks
  ADD CONSTRAINT resource_locks_job_id_fkey
  FOREIGN KEY(job_id) REFERENCES hcp.jobs(id) ON DELETE CASCADE;
ALTER TABLE hcp.resource_locks DROP COLUMN IF EXISTS fencing_token;

DELETE FROM hcp.schema_migrations
WHERE version=10 AND name='job_resource_leases';

COMMIT;
