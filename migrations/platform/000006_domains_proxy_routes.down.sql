BEGIN;

DELETE FROM hcp.schema_migrations
WHERE version = 6 AND name = 'domains_proxy_routes';

DROP TABLE IF EXISTS hcp.proxy_routes CASCADE;
DROP TABLE IF EXISTS hcp.domains CASCADE;

DELETE FROM hcp.role_permissions
WHERE permission_code IN (
  'domains.read',
  'domains.manage',
  'proxy.read',
  'proxy.manage'
);

DELETE FROM hcp.permissions
WHERE code IN (
  'domains.read',
  'domains.manage',
  'proxy.read',
  'proxy.manage'
);

DROP FUNCTION IF EXISTS hcp.enforce_proxy_route_status();
DROP FUNCTION IF EXISTS hcp.proxy_route_transition_allowed(text, text);
DROP FUNCTION IF EXISTS hcp.enforce_domain_status();
DROP FUNCTION IF EXISTS hcp.domain_status_transition_allowed(text, text);
DROP FUNCTION IF EXISTS hcp.enforce_domain_verification();
DROP FUNCTION IF EXISTS hcp.domain_verification_transition_allowed(text, text);
DROP FUNCTION IF EXISTS hcp.enforce_domain_quota();

COMMIT;
