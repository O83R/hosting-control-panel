BEGIN;

ALTER TABLE hcp.hosting_accounts
  ADD CONSTRAINT hosting_accounts_id_tenant_uq UNIQUE (id, tenant_id);

CREATE TABLE hcp.sites (
  id uuid PRIMARY KEY,
  tenant_id uuid NOT NULL REFERENCES hcp.tenants(id) ON DELETE CASCADE,
  account_id uuid NOT NULL,
  node_id uuid REFERENCES hcp.nodes(id) ON DELETE RESTRICT,
  site_key text NOT NULL,
  display_name text NOT NULL,
  kind text NOT NULL
    CHECK (kind IN ('containerized', 'static', 'external')),
  origin text NOT NULL DEFAULT 'managed'
    CHECK (origin IN ('managed', 'adopted')),
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'active', 'suspended', 'disabled')),
  source_ref text,
  desired_state jsonb NOT NULL DEFAULT '{}'::jsonb,
  observed_state jsonb NOT NULL DEFAULT '{}'::jsonb,
  version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  activated_at timestamptz,
  suspended_at timestamptz,
  disabled_at timestamptz,
  CHECK (site_key ~ '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$'),
  CHECK (origin <> 'adopted' OR source_ref IS NOT NULL),
  CHECK (status <> 'active' OR activated_at IS NOT NULL),
  CHECK (status <> 'suspended' OR suspended_at IS NOT NULL),
  CHECK (status <> 'disabled' OR disabled_at IS NOT NULL),
  UNIQUE (tenant_id, site_key),
  UNIQUE (id, tenant_id),
  FOREIGN KEY (account_id, tenant_id)
    REFERENCES hcp.hosting_accounts(id, tenant_id)
    ON DELETE CASCADE
);

CREATE INDEX sites_account_idx
  ON hcp.sites(account_id, status);

CREATE INDEX sites_node_idx
  ON hcp.sites(node_id)
  WHERE node_id IS NOT NULL;

CREATE OR REPLACE FUNCTION hcp.enforce_site_quota()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  package_limit integer;
  current_count integer;
BEGIN
  SELECT p.max_sites INTO package_limit
  FROM hcp.hosting_accounts a
  JOIN hcp.hosting_packages p ON p.id = a.package_id
  WHERE a.id = NEW.account_id
    AND a.tenant_id = NEW.tenant_id;

  IF package_limit IS NULL THEN
    RAISE EXCEPTION 'hosting account/package not found for site'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  SELECT count(*) INTO current_count
  FROM hcp.sites s
  WHERE s.account_id = NEW.account_id
    AND s.status <> 'disabled'
    AND (TG_OP = 'INSERT' OR s.id <> NEW.id);

  IF NEW.status <> 'disabled' AND current_count >= package_limit THEN
    RAISE EXCEPTION 'site quota exceeded for hosting account'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER sites_enforce_quota
BEFORE INSERT OR UPDATE OF account_id, tenant_id, status
ON hcp.sites
FOR EACH ROW
EXECUTE FUNCTION hcp.enforce_site_quota();

CREATE OR REPLACE FUNCTION hcp.site_transition_allowed(from_status text, to_status text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN from_status = 'pending' AND to_status IN ('active', 'disabled') THEN true
    WHEN from_status = 'active' AND to_status IN ('suspended', 'disabled') THEN true
    WHEN from_status = 'suspended' AND to_status IN ('active', 'disabled') THEN true
    ELSE false
  END;
$$;

CREATE OR REPLACE FUNCTION hcp.enforce_site_status()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;

  IF NOT hcp.site_transition_allowed(OLD.status, NEW.status) THEN
    RAISE EXCEPTION 'invalid site status transition: % -> %', OLD.status, NEW.status
      USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.status = 'active' THEN
    NEW.activated_at := COALESCE(OLD.activated_at, now());
  ELSIF NEW.status = 'suspended' THEN
    NEW.suspended_at := now();
  ELSIF NEW.status = 'disabled' THEN
    NEW.disabled_at := now();
  END IF;

  NEW.version := OLD.version + 1;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER sites_enforce_status
BEFORE UPDATE OF status ON hcp.sites
FOR EACH ROW
EXECUTE FUNCTION hcp.enforce_site_status();

CREATE TABLE hcp.site_adoption_candidates (
  id uuid PRIMARY KEY,
  tenant_id uuid NOT NULL REFERENCES hcp.tenants(id) ON DELETE CASCADE,
  node_id uuid NOT NULL REFERENCES hcp.nodes(id) ON DELETE RESTRICT,
  external_ref text NOT NULL,
  display_name text NOT NULL,
  runtime_kind text NOT NULL
    CHECK (runtime_kind IN ('containerized', 'static', 'external')),
  fingerprint text NOT NULL,
  status text NOT NULL DEFAULT 'detected'
    CHECK (status IN ('detected', 'reviewed', 'adopted', 'rejected')),
  observed_state jsonb NOT NULL DEFAULT '{}'::jsonb,
  adopted_site_id uuid,
  discovered_at timestamptz NOT NULL DEFAULT now(),
  reviewed_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (length(btrim(external_ref)) > 0),
  CHECK (length(btrim(fingerprint)) > 0),
  CHECK (status <> 'adopted' OR adopted_site_id IS NOT NULL),
  UNIQUE (node_id, external_ref),
  FOREIGN KEY (adopted_site_id, tenant_id)
    REFERENCES hcp.sites(id, tenant_id)
    ON DELETE SET NULL
);

CREATE INDEX site_adoption_candidates_tenant_status_idx
  ON hcp.site_adoption_candidates(tenant_id, status);

CREATE OR REPLACE FUNCTION hcp.adoption_transition_allowed(from_status text, to_status text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN from_status = 'detected' AND to_status IN ('reviewed', 'rejected') THEN true
    WHEN from_status = 'reviewed' AND to_status IN ('adopted', 'rejected') THEN true
    ELSE false
  END;
$$;

CREATE OR REPLACE FUNCTION hcp.enforce_adoption_status()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;

  IF NOT hcp.adoption_transition_allowed(OLD.status, NEW.status) THEN
    RAISE EXCEPTION 'invalid adoption status transition: % -> %', OLD.status, NEW.status
      USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.status IN ('reviewed', 'adopted', 'rejected') AND NEW.reviewed_at IS NULL THEN
    NEW.reviewed_at := now();
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER site_adoption_enforce_status
BEFORE UPDATE OF status ON hcp.site_adoption_candidates
FOR EACH ROW
EXECUTE FUNCTION hcp.enforce_adoption_status();

ALTER TABLE hcp.sites ENABLE ROW LEVEL SECURITY;
ALTER TABLE hcp.sites FORCE ROW LEVEL SECURITY;
CREATE POLICY sites_scope_policy ON hcp.sites
FOR ALL
USING (
  hcp.current_request_scope() = 'platform'
  OR tenant_id = hcp.current_tenant_id()
)
WITH CHECK (
  hcp.current_request_scope() = 'platform'
  OR tenant_id = hcp.current_tenant_id()
);

ALTER TABLE hcp.site_adoption_candidates ENABLE ROW LEVEL SECURITY;
ALTER TABLE hcp.site_adoption_candidates FORCE ROW LEVEL SECURITY;
CREATE POLICY site_adoption_scope_policy ON hcp.site_adoption_candidates
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
VALUES (5, 'sites_adoption');

COMMIT;
