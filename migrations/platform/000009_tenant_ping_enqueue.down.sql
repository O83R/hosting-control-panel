BEGIN;

DROP FUNCTION IF EXISTS hcp.enqueue_tenant_ping(
  uuid, uuid, text, text, text, text
);

DELETE FROM hcp.schema_migrations
WHERE version = 9 AND name = 'tenant_ping_enqueue';

COMMIT;
