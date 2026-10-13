BEGIN;

CREATE TABLE hcp.dns_provider_bindings (
  id uuid PRIMARY KEY,
  tenant_id uuid NOT NULL REFERENCES hcp.tenants(id) ON DELETE CASCADE,
  provider_type text NOT NULL
    CHECK (provider_type IN ('cloudflare', 'external')),
  mode text NOT NULL
    CHECK (mode IN ('managed', 'read_only')),
  zone_name text NOT NULL,
  provider_zone_ref text,
  credential_ref text,
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'disabled')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (zone_name = lower(zone_name)),
  CHECK (zone_name ~ '^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$'),
  CHECK (
    (provider_type = 'cloudflare' AND mode = 'managed'
      AND provider_zone_ref IS NOT NULL AND credential_ref IS NOT NULL)
    OR
    (provider_type = 'external' AND mode = 'read_only'
      AND credential_ref IS NULL)
  ),
  UNIQUE (tenant_id, zone_name),
  UNIQUE (id, tenant_id)
);

CREATE TABLE hcp.dns_records (
  id uuid PRIMARY KEY,
  tenant_id uuid NOT NULL REFERENCES hcp.tenants(id) ON DELETE CASCADE,
  domain_id uuid NOT NULL,
  binding_id uuid NOT NULL,
  provider_record_ref text,
  record_type text NOT NULL
    CHECK (record_type IN ('A', 'AAAA', 'CNAME', 'TXT', 'MX', 'CAA')),
  name text NOT NULL,
  content text NOT NULL,
  ttl integer NOT NULL DEFAULT 300
    CHECK (ttl BETWEEN 1 AND 86400),
  proxied boolean NOT NULL DEFAULT false,
  management_mode text NOT NULL
    CHECK (management_mode IN ('desired', 'observed')),
  status text NOT NULL
    CHECK (status IN ('observed', 'pending', 'applied', 'error', 'disabled')),
  version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (name = lower(name)),
  CHECK (length(btrim(content)) > 0),
  CHECK (
    (management_mode = 'observed' AND status = 'observed')
    OR management_mode = 'desired'
  ),
  UNIQUE (binding_id, record_type, name, content),
  FOREIGN KEY (domain_id, tenant_id)
    REFERENCES hcp.domains(id, tenant_id)
    ON DELETE CASCADE,
  FOREIGN KEY (binding_id, tenant_id)
    REFERENCES hcp.dns_provider_bindings(id, tenant_id)
    ON DELETE RESTRICT
);

CREATE INDEX dns_records_domain_idx
  ON hcp.dns_records(domain_id, status);

CREATE OR REPLACE FUNCTION hcp.enforce_dns_record_binding()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  binding_mode text;
  zone_value text;
  domain_fqdn text;
BEGIN
  SELECT mode, zone_name
  INTO binding_mode, zone_value
  FROM hcp.dns_provider_bindings
  WHERE id = NEW.binding_id
    AND tenant_id = NEW.tenant_id
    AND status = 'active';

  IF binding_mode IS NULL THEN
    RAISE EXCEPTION 'active DNS provider binding not found'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  SELECT fqdn INTO domain_fqdn
  FROM hcp.domains
  WHERE id = NEW.domain_id
    AND tenant_id = NEW.tenant_id;

  IF domain_fqdn IS NULL THEN
    RAISE EXCEPTION 'domain not found for DNS record'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF domain_fqdn <> zone_value
     AND right(domain_fqdn, length(zone_value) + 1) <> ('.' || zone_value) THEN
    RAISE EXCEPTION 'domain is outside provider zone'
      USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.name <> zone_value
     AND right(NEW.name, length(zone_value) + 1) <> ('.' || zone_value) THEN
    RAISE EXCEPTION 'record name is outside provider zone'
      USING ERRCODE = 'check_violation';
  END IF;

  IF binding_mode = 'read_only' THEN
    IF NEW.management_mode <> 'observed' OR NEW.status <> 'observed' THEN
      RAISE EXCEPTION 'read-only DNS binding accepts observed records only'
        USING ERRCODE = 'check_violation';
    END IF;
  ELSE
    IF NEW.management_mode <> 'desired' OR NEW.status = 'observed' THEN
      RAISE EXCEPTION 'managed DNS binding requires desired records'
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER dns_records_enforce_binding
BEFORE INSERT OR UPDATE OF tenant_id, domain_id, binding_id, name, management_mode, status
ON hcp.dns_records
FOR EACH ROW
EXECUTE FUNCTION hcp.enforce_dns_record_binding();

CREATE TABLE hcp.certificates (
  id uuid PRIMARY KEY,
  tenant_id uuid NOT NULL REFERENCES hcp.tenants(id) ON DELETE CASCADE,
  domain_id uuid NOT NULL,
  provider_type text NOT NULL
    CHECK (provider_type IN ('acme', 'manual', 'external')),
  challenge_type text
    CHECK (challenge_type IN ('dns-01', 'http-01', 'manual')),
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'issuing', 'active', 'failed', 'expired', 'revoked')),
  certificate_ref text,
  private_key_ref text,
  issuer_name text,
  serial_number text,
  not_before timestamptz,
  not_after timestamptz,
  renew_after timestamptz,
  last_error text,
  version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (provider_type <> 'acme' OR challenge_type IN ('dns-01', 'http-01')),
  CHECK (provider_type <> 'manual' OR challenge_type = 'manual'),
  CHECK (
    status <> 'active'
    OR (
      certificate_ref IS NOT NULL
      AND private_key_ref IS NOT NULL
      AND not_before IS NOT NULL
      AND not_after IS NOT NULL
      AND not_after > not_before
    )
  ),
  UNIQUE (domain_id),
  UNIQUE (id, tenant_id),
  FOREIGN KEY (domain_id, tenant_id)
    REFERENCES hcp.domains(id, tenant_id)
    ON DELETE CASCADE
);

CREATE INDEX certificates_status_idx
  ON hcp.certificates(tenant_id, status, renew_after);

CREATE OR REPLACE FUNCTION hcp.certificate_transition_allowed(from_status text, to_status text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN from_status = 'pending' AND to_status IN ('issuing', 'revoked') THEN true
    WHEN from_status = 'issuing' AND to_status IN ('active', 'failed', 'revoked') THEN true
    WHEN from_status = 'failed' AND to_status IN ('issuing', 'revoked') THEN true
    WHEN from_status = 'active' AND to_status IN ('issuing', 'expired', 'revoked') THEN true
    ELSE false
  END;
$$;

CREATE OR REPLACE FUNCTION hcp.enforce_certificate_status()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  domain_status_value text;
  verification_value text;
BEGIN
  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;

  IF NOT hcp.certificate_transition_allowed(OLD.status, NEW.status) THEN
    RAISE EXCEPTION 'invalid certificate status transition: % -> %', OLD.status, NEW.status
      USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.status = 'active' THEN
    SELECT status, verification_status
    INTO domain_status_value, verification_value
    FROM hcp.domains
    WHERE id = NEW.domain_id
      AND tenant_id = NEW.tenant_id;

    IF domain_status_value IS DISTINCT FROM 'active'
       OR verification_value IS DISTINCT FROM 'verified' THEN
      RAISE EXCEPTION 'active certificate requires active verified domain'
        USING ERRCODE = 'check_violation';
    END IF;

    IF NEW.certificate_ref IS NULL
       OR NEW.private_key_ref IS NULL
       OR NEW.not_before IS NULL
       OR NEW.not_after IS NULL
       OR NEW.not_after <= NEW.not_before THEN
      RAISE EXCEPTION 'active certificate metadata is incomplete'
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  NEW.version := OLD.version + 1;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER certificates_enforce_status
BEFORE UPDATE OF status ON hcp.certificates
FOR EACH ROW
EXECUTE FUNCTION hcp.enforce_certificate_status();

INSERT INTO hcp.permissions(code, scope, description) VALUES
  ('dns.read', 'tenant', 'Read DNS provider bindings and records'),
  ('dns.manage', 'tenant', 'Manage DNS provider bindings and desired records'),
  ('ssl.read', 'tenant', 'Read certificate metadata'),
  ('ssl.manage', 'tenant', 'Manage certificate intents and lifecycle');

INSERT INTO hcp.role_permissions(role_code, permission_code) VALUES
  ('tenant_owner', 'dns.read'),
  ('tenant_owner', 'dns.manage'),
  ('tenant_owner', 'ssl.read'),
  ('tenant_owner', 'ssl.manage'),
  ('tenant_admin', 'dns.read'),
  ('tenant_admin', 'dns.manage'),
  ('tenant_admin', 'ssl.read'),
  ('tenant_admin', 'ssl.manage'),
  ('tenant_operator', 'dns.read'),
  ('tenant_operator', 'ssl.read'),
  ('tenant_viewer', 'dns.read'),
  ('tenant_viewer', 'ssl.read');

ALTER TABLE hcp.dns_provider_bindings ENABLE ROW LEVEL SECURITY;
ALTER TABLE hcp.dns_provider_bindings FORCE ROW LEVEL SECURITY;
CREATE POLICY dns_provider_bindings_scope_policy ON hcp.dns_provider_bindings
FOR ALL
USING (hcp.current_request_scope() = 'platform' OR tenant_id = hcp.current_tenant_id())
WITH CHECK (hcp.current_request_scope() = 'platform' OR tenant_id = hcp.current_tenant_id());

ALTER TABLE hcp.dns_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE hcp.dns_records FORCE ROW LEVEL SECURITY;
CREATE POLICY dns_records_scope_policy ON hcp.dns_records
FOR ALL
USING (hcp.current_request_scope() = 'platform' OR tenant_id = hcp.current_tenant_id())
WITH CHECK (hcp.current_request_scope() = 'platform' OR tenant_id = hcp.current_tenant_id());

ALTER TABLE hcp.certificates ENABLE ROW LEVEL SECURITY;
ALTER TABLE hcp.certificates FORCE ROW LEVEL SECURITY;
CREATE POLICY certificates_scope_policy ON hcp.certificates
FOR ALL
USING (hcp.current_request_scope() = 'platform' OR tenant_id = hcp.current_tenant_id())
WITH CHECK (hcp.current_request_scope() = 'platform' OR tenant_id = hcp.current_tenant_id());

INSERT INTO hcp.schema_migrations(version, name)
VALUES (7, 'dns_ssl_adapters');

COMMIT;
