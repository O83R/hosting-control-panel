#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

IMAGE="${HCP_TEST_POSTGRES_IMAGE:-postgres:16-alpine}"
NAME="hcp-hosting-db-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
MIGRATIONS="$ROOT/migrations/platform"
OUT="$ROOT/.ci-out"

cleanup() {
  set +e
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$OUT"
mapfile -t UPS < <(find "$MIGRATIONS" -maxdepth 1 -type f -name '*.up.sql' | sort)
[ "${#UPS[@]}" -ge 4 ] || { echo "STOP: hosting migration chain incomplete" >&2; exit 1; }

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
  ('41000000-0000-0000-0000-000000000001', 'hosting-one', 'Hosting One'),
  ('41000000-0000-0000-0000-000000000002', 'hosting-two', 'Hosting Two');

INSERT INTO hcp.users(id, username) VALUES
  ('42000000-0000-0000-0000-000000000001', 'owner-one'),
  ('42000000-0000-0000-0000-000000000002', 'owner-two');

INSERT INTO hcp.tenant_memberships(tenant_id, user_id) VALUES
  ('41000000-0000-0000-0000-000000000001', '42000000-0000-0000-0000-000000000001'),
  ('41000000-0000-0000-0000-000000000002', '42000000-0000-0000-0000-000000000002');

INSERT INTO hcp.nodes(id, name, status)
VALUES ('43000000-0000-0000-0000-000000000001', 'ci-node-01', 'online');

INSERT INTO hcp.hosting_packages(
  id, tenant_id, code, display_name,
  max_sites, max_domains, max_databases, storage_mb
) VALUES
  (
    '44000000-0000-0000-0000-000000000001',
    '41000000-0000-0000-0000-000000000001',
    'starter-one', 'Starter One', 2, 4, 2, 2048
  ),
  (
    '44000000-0000-0000-0000-000000000002',
    '41000000-0000-0000-0000-000000000002',
    'starter-two', 'Starter Two', 1, 2, 1, 1024
  );

INSERT INTO hcp.hosting_accounts(
  id, tenant_id, package_id, owner_user_id, node_id,
  account_key, display_name
) VALUES (
  '45000000-0000-0000-0000-000000000001',
  '41000000-0000-0000-0000-000000000001',
  '44000000-0000-0000-0000-000000000001',
  '42000000-0000-0000-0000-000000000001',
  '43000000-0000-0000-0000-000000000001',
  'account-one', 'Account One'
);

UPDATE hcp.hosting_accounts
SET status='active'
WHERE id='45000000-0000-0000-0000-000000000001';

UPDATE hcp.hosting_accounts
SET status='suspended', suspension_reason='ci-test'
WHERE id='45000000-0000-0000-0000-000000000001';

UPDATE hcp.hosting_accounts
SET status='active', suspension_reason=NULL
WHERE id='45000000-0000-0000-0000-000000000001';

UPDATE hcp.hosting_accounts
SET status='disabled'
WHERE id='45000000-0000-0000-0000-000000000001';

DO $$
DECLARE
  v bigint;
  activated timestamptz;
  suspended timestamptz;
  disabled timestamptz;
BEGIN
  SELECT version, activated_at, suspended_at, disabled_at
  INTO v, activated, suspended, disabled
  FROM hcp.hosting_accounts
  WHERE id='45000000-0000-0000-0000-000000000001';

  IF v <> 5 OR activated IS NULL OR suspended IS NULL OR disabled IS NULL THEN
    RAISE EXCEPTION 'hosting account lifecycle contract failed';
  END IF;
END $$;
SQL

echo "HOSTING ACCOUNT LIFECYCLE: PASS"

if docker exec "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1   -c "UPDATE hcp.hosting_accounts SET status='active' WHERE id='45000000-0000-0000-0000-000000000001';"   >/dev/null 2>&1; then
  echo "STOP: disabled account transitioned back to active" >&2
  exit 1
fi

if docker exec "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1   -c "INSERT INTO hcp.hosting_accounts(id,tenant_id,package_id,owner_user_id,account_key,display_name) VALUES ('45000000-0000-0000-0000-000000000002','41000000-0000-0000-0000-000000000001','44000000-0000-0000-0000-000000000002','42000000-0000-0000-0000-000000000001','cross-package','Cross Package');"   >/dev/null 2>&1; then
  echo "STOP: cross-tenant package assignment was accepted" >&2
  exit 1
fi

if docker exec "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1   -c "INSERT INTO hcp.hosting_accounts(id,tenant_id,package_id,owner_user_id,account_key,display_name) VALUES ('45000000-0000-0000-0000-000000000003','41000000-0000-0000-0000-000000000001','44000000-0000-0000-0000-000000000001','42000000-0000-0000-0000-000000000002','wrong-owner','Wrong Owner');"   >/dev/null 2>&1; then
  echo "STOP: account owner without tenant membership was accepted" >&2
  exit 1
fi

echo "HOSTING TENANT CONSTRAINTS: PASS"

docker exec -i "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1 <<'SQL'
CREATE ROLE hcp_ci_hosting NOLOGIN;
GRANT USAGE ON SCHEMA hcp TO hcp_ci_hosting;
GRANT SELECT ON hcp.hosting_packages, hcp.hosting_accounts TO hcp_ci_hosting;

SET ROLE hcp_ci_hosting;
SET hcp.scope = 'tenant';
SET hcp.tenant_id = '41000000-0000-0000-0000-000000000001';

DO $$
DECLARE
  packages_seen integer;
  accounts_seen integer;
BEGIN
  SELECT count(*) INTO packages_seen FROM hcp.hosting_packages;
  SELECT count(*) INTO accounts_seen FROM hcp.hosting_accounts;
  IF packages_seen <> 1 THEN RAISE EXCEPTION 'package RLS leak: %', packages_seen; END IF;
  IF accounts_seen <> 1 THEN RAISE EXCEPTION 'account RLS leak: %', accounts_seen; END IF;
END $$;

RESET hcp.tenant_id;
DO $$
DECLARE
  packages_seen integer;
  accounts_seen integer;
BEGIN
  SELECT count(*) INTO packages_seen FROM hcp.hosting_packages;
  SELECT count(*) INTO accounts_seen FROM hcp.hosting_accounts;
  IF packages_seen <> 0 OR accounts_seen <> 0 THEN
    RAISE EXCEPTION 'hosting tenant context did not fail closed';
  END IF;
END $$;

RESET ROLE;
SQL

echo "HOSTING RLS ISOLATION: PASS"
echo "HOSTING FAIL-CLOSED CONTEXT: PASS"

permissions_count="$(docker exec "$NAME" psql -U postgres -d hcp_test -Atc "SELECT count(*) FROM hcp.permissions WHERE code IN ('accounts.read','accounts.manage','packages.read','packages.manage');")"
[[ "$permissions_count" == "4" ]] || { echo "STOP: hosting permission contract failed" >&2; exit 1; }

commit="${GITHUB_SHA:-local}"
run_id="${GITHUB_RUN_ID:-local}"
image_id="$(docker image inspect "$IMAGE" --format '{{.Id}}')"

python3 - "$OUT/hosting-db-receipt.json" "$commit" "$run_id" "$IMAGE" "$image_id" <<'PY'
import datetime,json,pathlib,sys
out,commit,run_id,image,image_id=sys.argv[1:]
payload={
  "schema_version":1,
  "verification":"hosting-accounts-packages",
  "commit":commit,
  "run_id":run_id,
  "postgres_image":image,
  "postgres_image_id":image_id,
  "production_database_access":False,
  "checks":{
    "package_model":"PASS",
    "account_lifecycle":"PASS",
    "cross_tenant_package_rejection":"PASS",
    "owner_membership_enforcement":"PASS",
    "tenant_rls_isolation":"PASS",
    "fail_closed_tenant_context":"PASS",
    "hosting_permissions":"PASS"
  },
  "verified_at":datetime.datetime.now(datetime.timezone.utc).isoformat()
}
pathlib.Path(out).write_text(json.dumps(payload,indent=2)+"\n",encoding="utf-8")
print(json.dumps(payload,indent=2))
PY

echo "HOSTING ACCOUNTS/PACKAGES CONTRACT: PASS"
echo "receipt=$OUT/hosting-db-receipt.json"
