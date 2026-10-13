BEGIN;

DELETE FROM hcp.schema_migrations
WHERE version = 7 AND name = 'dns_ssl_adapters';

DROP TABLE IF EXISTS hcp.certificates CASCADE;
DROP TABLE IF EXISTS hcp.dns_records CASCADE;
DROP TABLE IF EXISTS hcp.dns_provider_bindings CASCADE;

DELETE FROM hcp.role_permissions
WHERE permission_code IN ('dns.read', 'dns.manage', 'ssl.read', 'ssl.manage');

DELETE FROM hcp.permissions
WHERE code IN ('dns.read', 'dns.manage', 'ssl.read', 'ssl.manage');

DROP FUNCTION IF EXISTS hcp.enforce_certificate_status();
DROP FUNCTION IF EXISTS hcp.certificate_transition_allowed(text, text);
DROP FUNCTION IF EXISTS hcp.enforce_dns_record_binding();

COMMIT;
