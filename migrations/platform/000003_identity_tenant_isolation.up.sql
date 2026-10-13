BEGIN;

CREATE TABLE hcp.users (
  id uuid PRIMARY KEY,
  username text NOT NULL,
  email text,
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'suspended', 'disabled')),
  auth_version bigint NOT NULL DEFAULT 1 CHECK (auth_version > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  last_login_at timestamptz,
  CHECK (length(btrim(username)) BETWEEN 3 AND 64)
);

CREATE UNIQUE INDEX users_username_ci_uq
  ON hcp.users(lower(username));

CREATE UNIQUE INDEX users_email_ci_uq
  ON hcp.users(lower(email))
  WHERE email IS NOT NULL;

CREATE TABLE hcp.tenant_memberships (
  tenant_id uuid NOT NULL REFERENCES hcp.tenants(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES hcp.users(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'suspended')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, user_id)
);

CREATE INDEX tenant_memberships_user_idx
  ON hcp.tenant_memberships(user_id, tenant_id);

CREATE TABLE hcp.roles (
  code text PRIMARY KEY,
  scope text NOT NULL CHECK (scope IN ('platform', 'tenant')),
  display_name text NOT NULL,
  is_system boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (code ~ '^[a-z][a-z0-9_.-]{2,63}$')
);

CREATE TABLE hcp.permissions (
  code text PRIMARY KEY,
  scope text NOT NULL CHECK (scope IN ('platform', 'tenant')),
  description text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (code ~ '^[a-z][a-z0-9_.-]{2,95}$')
);

CREATE TABLE hcp.role_permissions (
  role_code text NOT NULL REFERENCES hcp.roles(code) ON DELETE CASCADE,
  permission_code text NOT NULL REFERENCES hcp.permissions(code) ON DELETE CASCADE,
  PRIMARY KEY (role_code, permission_code)
);

CREATE TABLE hcp.role_assignments (
  id bigserial PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES hcp.users(id) ON DELETE CASCADE,
  role_code text NOT NULL REFERENCES hcp.roles(code) ON DELETE RESTRICT,
  tenant_id uuid REFERENCES hcp.tenants(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX role_assignments_platform_uq
  ON hcp.role_assignments(user_id, role_code)
  WHERE tenant_id IS NULL;

CREATE UNIQUE INDEX role_assignments_tenant_uq
  ON hcp.role_assignments(user_id, role_code, tenant_id)
  WHERE tenant_id IS NOT NULL;

CREATE TABLE hcp.mfa_factors (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES hcp.users(id) ON DELETE CASCADE,
  factor_type text NOT NULL
    CHECK (factor_type IN ('totp', 'webauthn', 'recovery')),
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'active', 'revoked')),
  label text NOT NULL DEFAULT '',
  credential_ref text,
  created_at timestamptz NOT NULL DEFAULT now(),
  verified_at timestamptz,
  revoked_at timestamptz,
  CHECK (
    (status = 'pending' AND revoked_at IS NULL)
    OR (status = 'active' AND verified_at IS NOT NULL AND revoked_at IS NULL)
    OR (status = 'revoked' AND revoked_at IS NOT NULL)
  )
);

CREATE INDEX mfa_factors_user_idx
  ON hcp.mfa_factors(user_id, status);

INSERT INTO hcp.roles(code, scope, display_name) VALUES
  ('platform_owner', 'platform', 'Platform Owner'),
  ('platform_admin', 'platform', 'Platform Admin'),
  ('security_admin', 'platform', 'Security Admin'),
  ('node_operator', 'platform', 'Node Operator'),
  ('auditor', 'platform', 'Auditor'),
  ('tenant_owner', 'tenant', 'Tenant Owner'),
  ('tenant_admin', 'tenant', 'Tenant Admin'),
  ('tenant_operator', 'tenant', 'Tenant Operator'),
  ('tenant_viewer', 'tenant', 'Tenant Viewer');

INSERT INTO hcp.permissions(code, scope, description) VALUES
  ('platform.read', 'platform', 'Read platform metadata'),
  ('platform.manage', 'platform', 'Manage platform settings'),
  ('tenants.read', 'platform', 'Read tenants'),
  ('tenants.manage', 'platform', 'Manage tenants'),
  ('nodes.read', 'platform', 'Read nodes'),
  ('nodes.manage', 'platform', 'Manage nodes'),
  ('security.manage', 'platform', 'Manage security controls'),
  ('audit.read', 'platform', 'Read audit events'),
  ('tenant.read', 'tenant', 'Read tenant metadata'),
  ('tenant.manage', 'tenant', 'Manage tenant metadata'),
  ('sites.read', 'tenant', 'Read sites'),
  ('sites.manage', 'tenant', 'Manage sites'),
  ('backups.read', 'tenant', 'Read backup metadata'),
  ('backups.manage', 'tenant', 'Manage backup policies and runs');

INSERT INTO hcp.role_permissions(role_code, permission_code)
SELECT 'platform_owner', code FROM hcp.permissions;

INSERT INTO hcp.role_permissions(role_code, permission_code) VALUES
  ('platform_admin', 'platform.read'),
  ('platform_admin', 'platform.manage'),
  ('platform_admin', 'tenants.read'),
  ('platform_admin', 'tenants.manage'),
  ('platform_admin', 'nodes.read'),
  ('platform_admin', 'nodes.manage'),
  ('platform_admin', 'audit.read'),
  ('security_admin', 'platform.read'),
  ('security_admin', 'security.manage'),
  ('security_admin', 'audit.read'),
  ('node_operator', 'nodes.read'),
  ('node_operator', 'nodes.manage'),
  ('auditor', 'platform.read'),
  ('auditor', 'tenants.read'),
  ('auditor', 'nodes.read'),
  ('auditor', 'audit.read'),
  ('tenant_owner', 'tenant.read'),
  ('tenant_owner', 'tenant.manage'),
  ('tenant_owner', 'sites.read'),
  ('tenant_owner', 'sites.manage'),
  ('tenant_owner', 'backups.read'),
  ('tenant_owner', 'backups.manage'),
  ('tenant_admin', 'tenant.read'),
  ('tenant_admin', 'tenant.manage'),
  ('tenant_admin', 'sites.read'),
  ('tenant_admin', 'sites.manage'),
  ('tenant_admin', 'backups.read'),
  ('tenant_admin', 'backups.manage'),
  ('tenant_operator', 'tenant.read'),
  ('tenant_operator', 'sites.read'),
  ('tenant_operator', 'sites.manage'),
  ('tenant_operator', 'backups.read'),
  ('tenant_operator', 'backups.manage'),
  ('tenant_viewer', 'tenant.read'),
  ('tenant_viewer', 'sites.read'),
  ('tenant_viewer', 'backups.read');

CREATE OR REPLACE FUNCTION hcp.enforce_role_assignment_scope()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  role_scope text;
  membership_status text;
BEGIN
  SELECT scope INTO role_scope
  FROM hcp.roles
  WHERE code = NEW.role_code;

  IF role_scope IS NULL THEN
    RAISE EXCEPTION 'unknown role %', NEW.role_code;
  END IF;

  IF role_scope = 'platform' AND NEW.tenant_id IS NOT NULL THEN
    RAISE EXCEPTION 'platform role % cannot be tenant scoped', NEW.role_code
      USING ERRCODE = 'check_violation';
  END IF;

  IF role_scope = 'tenant' AND NEW.tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant role % requires tenant scope', NEW.role_code
      USING ERRCODE = 'check_violation';
  END IF;

  IF role_scope = 'tenant' THEN
    SELECT status INTO membership_status
    FROM hcp.tenant_memberships
    WHERE tenant_id = NEW.tenant_id AND user_id = NEW.user_id;

    IF membership_status IS DISTINCT FROM 'active' THEN
      RAISE EXCEPTION 'tenant role requires active tenant membership'
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER role_assignments_enforce_scope
BEFORE INSERT OR UPDATE OF user_id, role_code, tenant_id
ON hcp.role_assignments
FOR EACH ROW
EXECUTE FUNCTION hcp.enforce_role_assignment_scope();

CREATE OR REPLACE FUNCTION hcp.current_request_scope()
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(NULLIF(current_setting('hcp.scope', true), ''), 'tenant');
$$;

CREATE OR REPLACE FUNCTION hcp.current_tenant_id()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
  SELECT NULLIF(current_setting('hcp.tenant_id', true), '')::uuid;
$$;

ALTER TABLE hcp.tenants ENABLE ROW LEVEL SECURITY;
ALTER TABLE hcp.tenants FORCE ROW LEVEL SECURITY;
CREATE POLICY tenants_scope_policy ON hcp.tenants
FOR ALL
USING (
  hcp.current_request_scope() = 'platform'
  OR id = hcp.current_tenant_id()
)
WITH CHECK (
  hcp.current_request_scope() = 'platform'
  OR id = hcp.current_tenant_id()
);

ALTER TABLE hcp.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE hcp.users FORCE ROW LEVEL SECURITY;
CREATE POLICY users_scope_policy ON hcp.users
FOR ALL
USING (
  hcp.current_request_scope() = 'platform'
  OR EXISTS (
    SELECT 1
    FROM hcp.tenant_memberships tm
    WHERE tm.user_id = users.id
      AND tm.tenant_id = hcp.current_tenant_id()
  )
)
WITH CHECK (hcp.current_request_scope() = 'platform');

ALTER TABLE hcp.tenant_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE hcp.tenant_memberships FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_memberships_scope_policy ON hcp.tenant_memberships
FOR ALL
USING (
  hcp.current_request_scope() = 'platform'
  OR tenant_id = hcp.current_tenant_id()
)
WITH CHECK (
  hcp.current_request_scope() = 'platform'
  OR tenant_id = hcp.current_tenant_id()
);

ALTER TABLE hcp.role_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE hcp.role_assignments FORCE ROW LEVEL SECURITY;
CREATE POLICY role_assignments_scope_policy ON hcp.role_assignments
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
VALUES (3, 'identity_tenant_isolation');

COMMIT;
