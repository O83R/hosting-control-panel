BEGIN;

CREATE TABLE hcp.hosting_packages (
  id uuid PRIMARY KEY,
  tenant_id uuid NOT NULL REFERENCES hcp.tenants(id) ON DELETE CASCADE,
  code text NOT NULL,
  display_name text NOT NULL,
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'disabled')),
  max_sites integer NOT NULL DEFAULT 1 CHECK (max_sites > 0),
  max_domains integer NOT NULL DEFAULT 1 CHECK (max_domains >= 0),
  max_databases integer NOT NULL DEFAULT 1 CHECK (max_databases >= 0),
  storage_mb bigint NOT NULL DEFAULT 1024 CHECK (storage_mb > 0),
  bandwidth_mb bigint CHECK (bandwidth_mb IS NULL OR bandwidth_mb > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (code ~ '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$'),
  UNIQUE (tenant_id, code),
  UNIQUE (id, tenant_id)
);

CREATE TABLE hcp.hosting_accounts (
  id uuid PRIMARY KEY,
  tenant_id uuid NOT NULL REFERENCES hcp.tenants(id) ON DELETE CASCADE,
  package_id uuid NOT NULL,
  owner_user_id uuid NOT NULL REFERENCES hcp.users(id) ON DELETE RESTRICT,
  node_id uuid REFERENCES hcp.nodes(id) ON DELETE RESTRICT,
  account_key text NOT NULL,
  display_name text NOT NULL,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'active', 'suspended', 'disabled')),
  suspension_reason text,
  version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  activated_at timestamptz,
  suspended_at timestamptz,
  disabled_at timestamptz,
  CHECK (account_key ~ '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$'),
  CHECK (status <> 'active' OR activated_at IS NOT NULL),
  CHECK (status <> 'suspended' OR suspended_at IS NOT NULL),
  CHECK (status <> 'disabled' OR disabled_at IS NOT NULL),
  UNIQUE (tenant_id, account_key),
  FOREIGN KEY (package_id, tenant_id)
    REFERENCES hcp.hosting_packages(id, tenant_id)
    ON DELETE RESTRICT
);

CREATE INDEX hosting_accounts_owner_idx
  ON hcp.hosting_accounts(owner_user_id, tenant_id);

CREATE INDEX hosting_accounts_node_idx
  ON hcp.hosting_accounts(node_id)
  WHERE node_id IS NOT NULL;

CREATE OR REPLACE FUNCTION hcp.enforce_hosting_account_owner()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  membership_status text;
BEGIN
  SELECT status INTO membership_status
  FROM hcp.tenant_memberships
  WHERE tenant_id = NEW.tenant_id
    AND user_id = NEW.owner_user_id;

  IF membership_status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'hosting account owner requires active tenant membership'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER hosting_accounts_enforce_owner
BEFORE INSERT OR UPDATE OF tenant_id, owner_user_id
ON hcp.hosting_accounts
FOR EACH ROW
EXECUTE FUNCTION hcp.enforce_hosting_account_owner();

CREATE OR REPLACE FUNCTION hcp.hosting_account_transition_allowed(from_status text, to_status text)
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

CREATE OR REPLACE FUNCTION hcp.enforce_hosting_account_status()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;

  IF NOT hcp.hosting_account_transition_allowed(OLD.status, NEW.status) THEN
    RAISE EXCEPTION 'invalid hosting account status transition: % -> %', OLD.status, NEW.status
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

CREATE TRIGGER hosting_accounts_enforce_status
BEFORE UPDATE OF status ON hcp.hosting_accounts
FOR EACH ROW
EXECUTE FUNCTION hcp.enforce_hosting_account_status();

INSERT INTO hcp.permissions(code, scope, description) VALUES
  ('accounts.read', 'tenant', 'Read hosting accounts'),
  ('accounts.manage', 'tenant', 'Manage hosting accounts'),
  ('packages.read', 'tenant', 'Read hosting packages'),
  ('packages.manage', 'tenant', 'Manage hosting packages');

INSERT INTO hcp.role_permissions(role_code, permission_code) VALUES
  ('tenant_owner', 'accounts.read'),
  ('tenant_owner', 'accounts.manage'),
  ('tenant_owner', 'packages.read'),
  ('tenant_owner', 'packages.manage'),
  ('tenant_admin', 'accounts.read'),
  ('tenant_admin', 'accounts.manage'),
  ('tenant_admin', 'packages.read'),
  ('tenant_admin', 'packages.manage'),
  ('tenant_operator', 'accounts.read'),
  ('tenant_operator', 'packages.read'),
  ('tenant_viewer', 'accounts.read'),
  ('tenant_viewer', 'packages.read');

ALTER TABLE hcp.hosting_packages ENABLE ROW LEVEL SECURITY;
ALTER TABLE hcp.hosting_packages FORCE ROW LEVEL SECURITY;
CREATE POLICY hosting_packages_scope_policy ON hcp.hosting_packages
FOR ALL
USING (
  hcp.current_request_scope() = 'platform'
  OR tenant_id = hcp.current_tenant_id()
)
WITH CHECK (
  hcp.current_request_scope() = 'platform'
  OR tenant_id = hcp.current_tenant_id()
);

ALTER TABLE hcp.hosting_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE hcp.hosting_accounts FORCE ROW LEVEL SECURITY;
CREATE POLICY hosting_accounts_scope_policy ON hcp.hosting_accounts
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
VALUES (4, 'hosting_accounts_packages');

COMMIT;
