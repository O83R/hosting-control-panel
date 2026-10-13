BEGIN;

DELETE FROM hcp.schema_migrations
WHERE version = 3 AND name = 'identity_tenant_isolation';

DROP TABLE IF EXISTS hcp.mfa_factors CASCADE;
DROP TABLE IF EXISTS hcp.role_assignments CASCADE;
DROP TABLE IF EXISTS hcp.role_permissions CASCADE;
DROP TABLE IF EXISTS hcp.permissions CASCADE;
DROP TABLE IF EXISTS hcp.roles CASCADE;
DROP TABLE IF EXISTS hcp.tenant_memberships CASCADE;
DROP TABLE IF EXISTS hcp.users CASCADE;

DROP FUNCTION IF EXISTS hcp.current_tenant_id();
DROP FUNCTION IF EXISTS hcp.current_request_scope();
DROP FUNCTION IF EXISTS hcp.enforce_role_assignment_scope();

COMMIT;
