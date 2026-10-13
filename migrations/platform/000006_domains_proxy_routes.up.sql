BEGIN;

CREATE TABLE hcp.domains (
  id uuid PRIMARY KEY,
  tenant_id uuid NOT NULL REFERENCES hcp.tenants(id) ON DELETE CASCADE,
  site_id uuid NOT NULL,
  fqdn text NOT NULL,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'active', 'disabled')),
  verification_status text NOT NULL DEFAULT 'unverified'
    CHECK (verification_status IN ('unverified', 'pending', 'verified', 'failed')),
  dns_mode text NOT NULL DEFAULT 'external'
    CHECK (dns_mode IN ('external', 'managed')),
  ssl_mode text NOT NULL DEFAULT 'automatic'
    CHECK (ssl_mode IN ('off', 'automatic', 'manual')),
  version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  verified_at timestamptz,
  activated_at timestamptz,
  disabled_at timestamptz,
  CHECK (fqdn = lower(fqdn)),
  CHECK (length(fqdn) BETWEEN 3 AND 253),
  CHECK (fqdn ~ '^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$'),
  CHECK (status <> 'active' OR verification_status = 'verified'),
  CHECK (status <> 'active' OR activated_at IS NOT NULL),
  CHECK (status <> 'disabled' OR disabled_at IS NOT NULL),
  UNIQUE (fqdn),
  UNIQUE (id, tenant_id),
  FOREIGN KEY (site_id, tenant_id)
    REFERENCES hcp.sites(id, tenant_id)
    ON DELETE CASCADE
);

CREATE INDEX domains_site_idx
  ON hcp.domains(site_id, status);

CREATE OR REPLACE FUNCTION hcp.enforce_domain_quota()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  account_id_value uuid;
  package_limit integer;
  current_count integer;
BEGIN
  SELECT s.account_id, p.max_domains
  INTO account_id_value, package_limit
  FROM hcp.sites s
  JOIN hcp.hosting_accounts a
    ON a.id = s.account_id AND a.tenant_id = s.tenant_id
  JOIN hcp.hosting_packages p
    ON p.id = a.package_id AND p.tenant_id = a.tenant_id
  WHERE s.id = NEW.site_id
    AND s.tenant_id = NEW.tenant_id;

  IF package_limit IS NULL THEN
    RAISE EXCEPTION 'site/account/package not found for domain'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  SELECT count(*) INTO current_count
  FROM hcp.domains d
  JOIN hcp.sites s ON s.id = d.site_id AND s.tenant_id = d.tenant_id
  WHERE d.tenant_id = NEW.tenant_id
    AND s.account_id = account_id_value
    AND d.status <> 'disabled'
    AND (TG_OP = 'INSERT' OR d.id <> NEW.id);

  IF NEW.status <> 'disabled' AND current_count >= package_limit THEN
    RAISE EXCEPTION 'domain quota exceeded for hosting account'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER domains_enforce_quota
BEFORE INSERT OR UPDATE OF site_id, tenant_id, status
ON hcp.domains
FOR EACH ROW
EXECUTE FUNCTION hcp.enforce_domain_quota();

CREATE OR REPLACE FUNCTION hcp.domain_verification_transition_allowed(from_status text, to_status text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN from_status = 'unverified' AND to_status = 'pending' THEN true
    WHEN from_status = 'pending' AND to_status IN ('verified', 'failed') THEN true
    WHEN from_status = 'failed' AND to_status = 'pending' THEN true
    ELSE false
  END;
$$;

CREATE OR REPLACE FUNCTION hcp.enforce_domain_verification()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.verification_status = OLD.verification_status THEN
    RETURN NEW;
  END IF;

  IF NOT hcp.domain_verification_transition_allowed(OLD.verification_status, NEW.verification_status) THEN
    RAISE EXCEPTION 'invalid domain verification transition: % -> %', OLD.verification_status, NEW.verification_status
      USING ERRCODE = 'check_violation';
  END IF;

  IF OLD.verification_status = 'verified' AND NEW.verification_status <> 'verified' AND NEW.status = 'active' THEN
    RAISE EXCEPTION 'active domain cannot lose verification'
      USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.verification_status = 'verified' THEN
    NEW.verified_at := now();
  END IF;

  NEW.version := OLD.version + 1;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER domains_enforce_verification
BEFORE UPDATE OF verification_status ON hcp.domains
FOR EACH ROW
EXECUTE FUNCTION hcp.enforce_domain_verification();

CREATE OR REPLACE FUNCTION hcp.domain_status_transition_allowed(from_status text, to_status text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN from_status = 'pending' AND to_status IN ('active', 'disabled') THEN true
    WHEN from_status = 'active' AND to_status = 'disabled' THEN true
    WHEN from_status = 'disabled' AND to_status = 'active' THEN true
    ELSE false
  END;
$$;

CREATE OR REPLACE FUNCTION hcp.enforce_domain_status()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;

  IF NOT hcp.domain_status_transition_allowed(OLD.status, NEW.status) THEN
    RAISE EXCEPTION 'invalid domain status transition: % -> %', OLD.status, NEW.status
      USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.status = 'active' AND NEW.verification_status <> 'verified' THEN
    RAISE EXCEPTION 'domain must be verified before activation'
      USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.status = 'active' THEN
    NEW.activated_at := COALESCE(OLD.activated_at, now());
  ELSIF NEW.status = 'disabled' THEN
    NEW.disabled_at := now();
  END IF;

  NEW.version := OLD.version + 1;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER domains_enforce_status
BEFORE UPDATE OF status ON hcp.domains
FOR EACH ROW
EXECUTE FUNCTION hcp.enforce_domain_status();

CREATE TABLE hcp.proxy_routes (
  id uuid PRIMARY KEY,
  tenant_id uuid NOT NULL REFERENCES hcp.tenants(id) ON DELETE CASCADE,
  domain_id uuid NOT NULL,
  path_prefix text NOT NULL DEFAULT '/',
  target_scheme text NOT NULL
    CHECK (target_scheme IN ('http', 'https')),
  target_host text NOT NULL,
  target_port integer NOT NULL
    CHECK (target_port BETWEEN 1 AND 65535),
  preserve_host boolean NOT NULL DEFAULT true,
  websocket boolean NOT NULL DEFAULT true,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'active', 'disabled')),
  version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  activated_at timestamptz,
  disabled_at timestamptz,
  CHECK (path_prefix ~ '^/[^?#]*$'),
  CHECK (length(btrim(target_host)) > 0),
  CHECK (target_host !~ '://'),
  CHECK (target_host !~ '[/?#[:space:]]'),
  CHECK (status <> 'active' OR activated_at IS NOT NULL),
  UNIQUE (domain_id, path_prefix),
  FOREIGN KEY (domain_id, tenant_id)
    REFERENCES hcp.domains(id, tenant_id)
    ON DELETE CASCADE
);

CREATE INDEX proxy_routes_tenant_status_idx
  ON hcp.proxy_routes(tenant_id, status);

CREATE OR REPLACE FUNCTION hcp.proxy_route_transition_allowed(from_status text, to_status text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN from_status = 'pending' AND to_status IN ('active', 'disabled') THEN true
    WHEN from_status = 'active' AND to_status = 'disabled' THEN true
    WHEN from_status = 'disabled' AND to_status = 'active' THEN true
    ELSE false
  END;
$$;

CREATE OR REPLACE FUNCTION hcp.enforce_proxy_route_status()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  domain_status_value text;
  domain_verification_value text;
  site_status_value text;
BEGIN
  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;

  IF NOT hcp.proxy_route_transition_allowed(OLD.status, NEW.status) THEN
    RAISE EXCEPTION 'invalid proxy route status transition: % -> %', OLD.status, NEW.status
      USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.status = 'active' THEN
    SELECT d.status, d.verification_status, s.status
    INTO domain_status_value, domain_verification_value, site_status_value
    FROM hcp.domains d
    JOIN hcp.sites s
      ON s.id = d.site_id AND s.tenant_id = d.tenant_id
    WHERE d.id = NEW.domain_id
      AND d.tenant_id = NEW.tenant_id;

    IF domain_status_value IS DISTINCT FROM 'active'
       OR domain_verification_value IS DISTINCT FROM 'verified'
       OR site_status_value IS DISTINCT FROM 'active' THEN
      RAISE EXCEPTION 'proxy route requires active verified domain and active site'
        USING ERRCODE = 'check_violation';
    END IF;

    NEW.activated_at := COALESCE(OLD.activated_at, now());
  ELSIF NEW.status = 'disabled' THEN
    NEW.disabled_at := now();
  END IF;

  NEW.version := OLD.version + 1;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER proxy_routes_enforce_status
BEFORE UPDATE OF status ON hcp.proxy_routes
FOR EACH ROW
EXECUTE FUNCTION hcp.enforce_proxy_route_status();

INSERT INTO hcp.permissions(code, scope, description) VALUES
  ('domains.read', 'tenant', 'Read tenant domains'),
  ('domains.manage', 'tenant', 'Manage tenant domains'),
  ('proxy.read', 'tenant', 'Read reverse proxy routes'),
  ('proxy.manage', 'tenant', 'Manage reverse proxy routes');

INSERT INTO hcp.role_permissions(role_code, permission_code) VALUES
  ('tenant_owner', 'domains.read'),
  ('tenant_owner', 'domains.manage'),
  ('tenant_owner', 'proxy.read'),
  ('tenant_owner', 'proxy.manage'),
  ('tenant_admin', 'domains.read'),
  ('tenant_admin', 'domains.manage'),
  ('tenant_admin', 'proxy.read'),
  ('tenant_admin', 'proxy.manage'),
  ('tenant_operator', 'domains.read'),
  ('tenant_operator', 'proxy.read'),
  ('tenant_operator', 'proxy.manage'),
  ('tenant_viewer', 'domains.read'),
  ('tenant_viewer', 'proxy.read');

ALTER TABLE hcp.domains ENABLE ROW LEVEL SECURITY;
ALTER TABLE hcp.domains FORCE ROW LEVEL SECURITY;
CREATE POLICY domains_scope_policy ON hcp.domains
FOR ALL
USING (
  hcp.current_request_scope() = 'platform'
  OR tenant_id = hcp.current_tenant_id()
)
WITH CHECK (
  hcp.current_request_scope() = 'platform'
  OR tenant_id = hcp.current_tenant_id()
);

ALTER TABLE hcp.proxy_routes ENABLE ROW LEVEL SECURITY;
ALTER TABLE hcp.proxy_routes FORCE ROW LEVEL SECURITY;
CREATE POLICY proxy_routes_scope_policy ON hcp.proxy_routes
FOR ALL
USING (
  hcp.current_request_scope() = 'platform'
  OR tenant_id = hcp.current_tenant_id()
)
WITH CHECK (
  hcp.current_request_scope() = 'platform'
  OR tenant_id = hcp.current_tenant_id()
);

INSERT INTO hcp.schema_migrations(version, name)
VALUES (6, 'domains_proxy_routes');

COMMIT;
