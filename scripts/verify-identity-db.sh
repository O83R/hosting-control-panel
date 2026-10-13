#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

IMAGE="${HCP_TEST_POSTGRES_IMAGE:-postgres:16-alpine}"
NAME="hcp-identity-db-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
MIGRATIONS="$ROOT/migrations/platform"
OUT="$ROOT/.ci-out"

cleanup() {
  set +e
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$OUT"

mapfile -t UPS < <(find "$MIGRATIONS" -maxdepth 1 -type f -name '*.up.sql' | sort)
[ "${#UPS[@]}" -ge 3 ] || { echo "STOP: identity migration chain incomplete" >&2; exit 1; }

docker run -d   --name "$NAME"   -e POSTGRES_PASSWORD=hcp_ci_only   -e POSTGRES_DB=hcp_test   "$IMAGE" >/dev/null

stable=0
for _ in $(seq 1 60); do
  if docker exec "$NAME" psql -U postgres -d hcp_test -Atqc 'SELECT 1;' >/dev/null 2>&1; then
    stable=$((stable + 1))
    (( stable >= 3 )) && break
  else
    stable=0
  fi
  sleep 1
done
(( stable >= 3 )) || { docker logs "$NAME" || true; echo "STOP: PostgreSQL not stably ready" >&2; exit 1; }

for migration in "${UPS[@]}"; do
  docker exec -i "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1 <"$migration"
done

docker exec -i "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO hcp.tenants(id, slug, display_name) VALUES
  ('10000000-0000-0000-0000-000000000001', 'tenant-one', 'Tenant One'),
  ('10000000-0000-0000-0000-000000000002', 'tenant-two', 'Tenant Two');

INSERT INTO hcp.users(id, username, email) VALUES
  ('20000000-0000-0000-0000-000000000001', 'alice', 'alice@example.invalid'),
  ('20000000-0000-0000-0000-000000000002', 'bob', 'bob@example.invalid'),
  ('20000000-0000-0000-0000-000000000003', 'platform-admin', 'admin@example.invalid');

INSERT INTO hcp.tenant_memberships(tenant_id, user_id) VALUES
  ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001'),
  ('10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000002');

INSERT INTO hcp.role_assignments(user_id, role_code, tenant_id) VALUES
  ('20000000-0000-0000-0000-000000000001', 'tenant_admin', '10000000-0000-0000-0000-000000000001'),
  ('20000000-0000-0000-0000-000000000002', 'tenant_viewer', '10000000-0000-0000-0000-000000000002'),
  ('20000000-0000-0000-0000-000000000003', 'platform_admin', NULL);

INSERT INTO hcp.mfa_factors(id, user_id, factor_type, status, label, credential_ref, verified_at)
VALUES (
  '30000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-000000000003',
  'totp', 'active', 'primary', 'secretref://ci/not-a-secret', now()
);
SQL

echo "IDENTITY SEED: PASS"

if docker exec "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1   -c "INSERT INTO hcp.role_assignments(user_id,role_code,tenant_id) VALUES ('20000000-0000-0000-0000-000000000003','platform_admin','10000000-0000-0000-0000-000000000001');"   >/dev/null 2>&1; then
  echo "STOP: platform role accepted tenant scope" >&2
  exit 1
fi

if docker exec "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1   -c "INSERT INTO hcp.role_assignments(user_id,role_code,tenant_id) VALUES ('20000000-0000-0000-0000-000000000003','tenant_admin',NULL);"   >/dev/null 2>&1; then
  echo "STOP: tenant role accepted without tenant scope" >&2
  exit 1
fi

if docker exec "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1   -c "INSERT INTO hcp.role_assignments(user_id,role_code,tenant_id) VALUES ('20000000-0000-0000-0000-000000000003','tenant_admin','10000000-0000-0000-0000-000000000001');"   >/dev/null 2>&1; then
  echo "STOP: tenant role accepted without active membership" >&2
  exit 1
fi

echo "ROLE SCOPE CONSTRAINTS: PASS"

docker exec -i "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1 <<'SQL'
CREATE ROLE hcp_ci_tenant NOLOGIN;
GRANT USAGE ON SCHEMA hcp TO hcp_ci_tenant;
GRANT SELECT ON hcp.tenants, hcp.users, hcp.tenant_memberships, hcp.role_assignments TO hcp_ci_tenant;

SET ROLE hcp_ci_tenant;
SET hcp.scope = 'tenant';
SET hcp.tenant_id = '10000000-0000-0000-0000-000000000001';

DO $$
DECLARE
  tenants_seen integer;
  users_seen integer;
  memberships_seen integer;
  assignments_seen integer;
BEGIN
  SELECT count(*) INTO tenants_seen FROM hcp.tenants;
  SELECT count(*) INTO users_seen FROM hcp.users;
  SELECT count(*) INTO memberships_seen FROM hcp.tenant_memberships;
  SELECT count(*) INTO assignments_seen FROM hcp.role_assignments;

  IF tenants_seen <> 1 THEN RAISE EXCEPTION 'tenant RLS leaked tenants: %', tenants_seen; END IF;
  IF users_seen <> 1 THEN RAISE EXCEPTION 'tenant RLS leaked users: %', users_seen; END IF;
  IF memberships_seen <> 1 THEN RAISE EXCEPTION 'tenant RLS leaked memberships: %', memberships_seen; END IF;
  IF assignments_seen <> 1 THEN RAISE EXCEPTION 'tenant RLS leaked assignments: %', assignments_seen; END IF;
END $$;

RESET hcp.tenant_id;
DO $$
DECLARE
  tenants_seen integer;
BEGIN
  SELECT count(*) INTO tenants_seen FROM hcp.tenants;
  IF tenants_seen <> 0 THEN
    RAISE EXCEPTION 'tenant scope without tenant id must fail closed, saw % rows', tenants_seen;
  END IF;
END $$;
RESET ROLE;
SQL

echo "TENANT RLS ISOLATION: PASS"
echo "FAIL-CLOSED TENANT CONTEXT: PASS"

roles_count="$(docker exec "$NAME" psql -U postgres -d hcp_test -Atc "SELECT count(*) FROM hcp.roles;")"
permissions_count="$(docker exec "$NAME" psql -U postgres -d hcp_test -Atc "SELECT count(*) FROM hcp.permissions WHERE code IN ('platform.read','platform.manage','tenants.read','tenants.manage','nodes.read','nodes.manage','security.manage','audit.read','tenant.read','tenant.manage','sites.read','sites.manage','backups.read','backups.manage');")"
mfa_active="$(docker exec "$NAME" psql -U postgres -d hcp_test -Atc "SELECT count(*) FROM hcp.mfa_factors WHERE status='active';")"
[[ "$roles_count" == "9" ]] || { echo "STOP: expected 9 roles, got $roles_count" >&2; exit 1; }
[[ "$permissions_count" == "14" ]] || { echo "STOP: Phase 02 permission baseline incomplete: got $permissions_count of 14" >&2; exit 1; }
[[ "$mfa_active" == "1" ]] || { echo "STOP: MFA contract failed" >&2; exit 1; }

commit="${GITHUB_SHA:-local}"
run_id="${GITHUB_RUN_ID:-local}"
image_id="$(docker image inspect "$IMAGE" --format '{{.Id}}')"

python3 - "$OUT/identity-db-receipt.json" "$commit" "$run_id" "$IMAGE" "$image_id" <<'PY'
import datetime,json,pathlib,sys
out,commit,run_id,image,image_id=sys.argv[1:]
payload={
  "schema_version":1,
  "verification":"identity-tenant-isolation",
  "commit":commit,
  "run_id":run_id,
  "postgres_image":image,
  "postgres_image_id":image_id,
  "production_database_access":False,
  "checks":{
    "identity_schema":"PASS",
    "role_scope_constraints":"PASS",
    "tenant_rls_isolation":"PASS",
    "fail_closed_tenant_context":"PASS",
    "mfa_model":"PASS"
  },
  "verified_at":datetime.datetime.now(datetime.timezone.utc).isoformat()
}
pathlib.Path(out).write_text(json.dumps(payload,indent=2)+"\n",encoding="utf-8")
print(json.dumps(payload,indent=2))
PY

echo "IDENTITY TENANT ISOLATION: PASS"
echo "receipt=$OUT/identity-db-receipt.json"
