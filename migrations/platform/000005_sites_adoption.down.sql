BEGIN;

DELETE FROM hcp.schema_migrations
WHERE version = 5 AND name = 'sites_adoption';

DROP TABLE IF EXISTS hcp.site_adoption_candidates CASCADE;
DROP TABLE IF EXISTS hcp.sites CASCADE;

DROP FUNCTION IF EXISTS hcp.enforce_adoption_status();
DROP FUNCTION IF EXISTS hcp.adoption_transition_allowed(text, text);
DROP FUNCTION IF EXISTS hcp.enforce_site_status();
DROP FUNCTION IF EXISTS hcp.site_transition_allowed(text, text);
DROP FUNCTION IF EXISTS hcp.enforce_site_quota();

ALTER TABLE hcp.hosting_accounts
  DROP CONSTRAINT IF EXISTS hosting_accounts_id_tenant_uq;

COMMIT;
