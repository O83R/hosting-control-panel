BEGIN;

DELETE FROM hcp.schema_migrations
WHERE version = 4 AND name = 'hosting_accounts_packages';

DROP TABLE IF EXISTS hcp.hosting_accounts CASCADE;
DROP TABLE IF EXISTS hcp.hosting_packages CASCADE;

DELETE FROM hcp.role_permissions
WHERE permission_code IN (
  'accounts.read',
  'accounts.manage',
  'packages.read',
  'packages.manage'
);

DELETE FROM hcp.permissions
WHERE code IN (
  'accounts.read',
  'accounts.manage',
  'packages.read',
  'packages.manage'
);

DROP FUNCTION IF EXISTS hcp.enforce_hosting_account_status();
DROP FUNCTION IF EXISTS hcp.hosting_account_transition_allowed(text, text);
DROP FUNCTION IF EXISTS hcp.enforce_hosting_account_owner();

COMMIT;
