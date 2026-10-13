#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

IMAGE="${HCP_TEST_POSTGRES_IMAGE:-postgres:16-alpine}"
NAME="hcp-networking-db-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
MIGRATIONS="$ROOT/migrations/platform"
OUT="$ROOT/.ci-out"

cleanup() {
  set +e
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$OUT"
mapfile -t UPS < <(find "$MIGRATIONS" -maxdepth 1 -type f -name '*.up.sql' | sort)
[ "${#UPS[@]}" -ge 6 ] || { echo "STOP: networking migration chain incomplete" >&2; exit 1; }

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
  ('61000000-0000-0000-0000-000000000001', 'network-one', 'Network One'),
  ('61000000-0000-0000-0000-000000000002', 'network-two', 'Network Two');

INSERT INTO hcp.users(id, username) VALUES
  ('62000000-0000-0000-0000-000000000001', 'network-owner-one'),
  ('62000000-0000-0000-0000-000000000002', 'network-owner-two');

INSERT INTO hcp.tenant_memberships(tenant_id, user_id) VALUES
  ('61000000-0000-0000-0000-000000000001', '62000000-0000-0000-0000-000000000001'),
  ('61000000-0000-0000-0000-000000000002', '62000000-0000-0000-0000-000000000002');

INSERT INTO hcp.nodes(id, name, status) VALUES
  ('63000000-0000-0000-0000-000000000001', 'network-node-01', 'online');

INSERT INTO hcp.hosting_packages(
  id, tenant_id, code, display_name,
  max_sites, max_domains, max_databases, storage_mb
) VALUES
  (
    '64000000-0000-0000-0000-000000000001',
    '61000000-0000-0000-0000-000000000001',
    'single-domain', 'Single Domain', 2, 1, 1, 1024
  ),
  (
    '64000000-0000-0000-0000-000000000002',
    '61000000-0000-0000-0000-000000000002',
    'tenant-two', 'Tenant Two', 2, 2, 1, 1024
  );

INSERT INTO hcp.hosting_accounts(
  id, tenant_id, package_id, owner_user_id, node_id,
  account_key, display_name
) VALUES
  (
    '65000000-0000-0000-0000-000000000001',
    '61000000-0000-0000-0000-000000000001',
    '64000000-0000-0000-0000-000000000001',
    '62000000-0000-0000-0000-000000000001',
    '63000000-0000-0000-0000-000000000001',
    'account-one', 'Account One'
  ),
  (
    '65000000-0000-0000-0000-000000000002',
    '61000000-0000-0000-0000-000000000002',
    '64000000-0000-0000-0000-000000000002',
    '62000000-0000-0000-0000-000000000002',
    '63000000-0000-0000-0000-000000000001',
    'account-two', 'Account Two'
  );

INSERT INTO hcp.sites(
  id, tenant_id, account_id, node_id,
  site_key, display_name, kind, origin
) VALUES
  (
    '66000000-0000-0000-0000-000000000001',
    '61000000-0000-0000-0000-000000000001',
    '65000000-0000-0000-0000-000000000001',
    '63000000-0000-0000-0000-000000000001',
    'site-one', 'Site One', 'containerized', 'managed'
  ),
  (
    '66000000-0000-0000-0000-000000000002',
    '61000000-0000-0000-0000-000000000002',
    '65000000-0000-0000-0000-000000000002',
    '63000000-0000-0000-0000-000000000001',
    'site-two', 'Site Two', 'containerized', 'managed'
  );

UPDATE hcp.sites
SET status='active'
WHERE id IN (
  '66000000-0000-0000-0000-000000000001',
  '66000000-0000-0000-0000-000000000002'
);

INSERT INTO hcp.domains(
  id, tenant_id, site_id, fqdn, dns_mode, ssl_mode
) VALUES (
  '67000000-0000-0000-0000-000000000001',
  '61000000-0000-0000-0000-000000000001',
  '66000000-0000-0000-0000-000000000001',
  'app.example.test', 'external', 'automatic'
);

INSERT INTO hcp.proxy_routes(
  id, tenant_id, domain_id, path_prefix,
  target_scheme, target_host, target_port
) VALUES (
  '68000000-0000-0000-0000-000000000001',
  '61000000-0000-0000-0000-000000000001',
  '67000000-0000-0000-0000-000000000001',
  '/', 'http', 'backend', 8080
);
SQL

if docker exec "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1   -c "UPDATE hcp.domains SET status='active' WHERE id='67000000-0000-0000-0000-000000000001';"   >/dev/null 2>&1; then
  echo "STOP: unverified domain activated" >&2
  exit 1
fi

if docker exec "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1   -c "UPDATE hcp.proxy_routes SET status='active' WHERE id='68000000-0000-0000-0000-000000000001';"   >/dev/null 2>&1; then
  echo "STOP: proxy route activated before domain verification" >&2
  exit 1
fi

docker exec "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1   -c "UPDATE hcp.domains SET verification_status='pending' WHERE id='67000000-0000-0000-0000-000000000001';" >/dev/null

docker exec "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1   -c "UPDATE hcp.domains SET verification_status='verified' WHERE id='67000000-0000-0000-0000-000000000001';" >/dev/null

docker exec "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1   -c "UPDATE hcp.domains SET status='active' WHERE id='67000000-0000-0000-0000-000000000001';" >/dev/null

docker exec "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1   -c "UPDATE hcp.proxy_routes SET status='active' WHERE id='68000000-0000-0000-0000-000000000001';" >/dev/null

echo "DOMAIN VERIFICATION / PROXY ACTIVATION: PASS"

if docker exec "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1   -c "INSERT INTO hcp.domains(id,tenant_id,site_id,fqdn) VALUES ('67000000-0000-0000-0000-000000000002','61000000-0000-0000-0000-000000000001','66000000-0000-0000-0000-000000000001','second.example.test');"   >/dev/null 2>&1; then
  echo "STOP: package max_domains quota was not enforced" >&2
  exit 1
fi

if docker exec "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1   -c "INSERT INTO hcp.domains(id,tenant_id,site_id,fqdn) VALUES ('67000000-0000-0000-0000-000000000003','61000000-0000-0000-0000-000000000002','66000000-0000-0000-0000-000000000002','app.example.test');"   >/dev/null 2>&1; then
  echo "STOP: duplicate global fqdn was accepted" >&2
  exit 1
fi

if docker exec "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1   -c "INSERT INTO hcp.domains(id,tenant_id,site_id,fqdn) VALUES ('67000000-0000-0000-0000-000000000004','61000000-0000-0000-0000-000000000001','66000000-0000-0000-0000-000000000002','cross.example.test');"   >/dev/null 2>&1; then
  echo "STOP: cross-tenant site/domain assignment was accepted" >&2
  exit 1
fi

if docker exec "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1   -c "INSERT INTO hcp.proxy_routes(id,tenant_id,domain_id,path_prefix,target_scheme,target_host,target_port) VALUES ('68000000-0000-0000-0000-000000000002','61000000-0000-0000-0000-000000000002','67000000-0000-0000-0000-000000000001','/admin','http','backend',8080);"   >/dev/null 2>&1; then
  echo "STOP: cross-tenant proxy/domain assignment was accepted" >&2
  exit 1
fi

echo "NETWORKING TENANT / QUOTA / FQDN GATES: PASS"

docker exec -i "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1 <<'SQL'
CREATE ROLE hcp_ci_networking NOLOGIN;
GRANT USAGE ON SCHEMA hcp TO hcp_ci_networking;
GRANT SELECT ON hcp.domains, hcp.proxy_routes TO hcp_ci_networking;

SET ROLE hcp_ci_networking;
SET hcp.scope = 'tenant';
SET hcp.tenant_id = '61000000-0000-0000-0000-000000000001';

DO $$
DECLARE
  domains_seen integer;
  routes_seen integer;
BEGIN
  SELECT count(*) INTO domains_seen FROM hcp.domains;
  SELECT count(*) INTO routes_seen FROM hcp.proxy_routes;
  IF domains_seen <> 1 THEN RAISE EXCEPTION 'domain RLS mismatch: %', domains_seen; END IF;
  IF routes_seen <> 1 THEN RAISE EXCEPTION 'proxy RLS mismatch: %', routes_seen; END IF;
END $$;

RESET hcp.tenant_id;
DO $$
DECLARE
  domains_seen integer;
  routes_seen integer;
BEGIN
  SELECT count(*) INTO domains_seen FROM hcp.domains;
  SELECT count(*) INTO routes_seen FROM hcp.proxy_routes;
  IF domains_seen <> 0 OR routes_seen <> 0 THEN
    RAISE EXCEPTION 'networking tenant context did not fail closed';
  END IF;
END $$;

RESET ROLE;
SQL

echo "NETWORKING RLS ISOLATION: PASS"
echo "NETWORKING FAIL-CLOSED CONTEXT: PASS"

permissions_count="$(docker exec "$NAME" psql -U postgres -d hcp_test -Atc "SELECT count(*) FROM hcp.permissions WHERE code IN ('domains.read','domains.manage','proxy.read','proxy.manage');")"
[[ "$permissions_count" == "4" ]] || { echo "STOP: networking permission contract failed" >&2; exit 1; }

commit="${GITHUB_SHA:-local}"
run_id="${GITHUB_RUN_ID:-local}"
image_id="$(docker image inspect "$IMAGE" --format '{{.Id}}')"

python3 - "$OUT/networking-db-receipt.json" "$commit" "$run_id" "$IMAGE" "$image_id" <<'PY'
import datetime,json,pathlib,sys
out,commit,run_id,image,image_id=sys.argv[1:]
payload={
  "schema_version":1,
  "verification":"domains-proxy-routes",
  "commit":commit,
  "run_id":run_id,
  "postgres_image":image,
  "postgres_image_id":image_id,
  "production_database_access":False,
  "production_mutation":False,
  "checks":{
    "domain_verification":"PASS",
    "proxy_activation_guard":"PASS",
    "domain_quota":"PASS",
    "global_fqdn_uniqueness":"PASS",
    "cross_tenant_rejection":"PASS",
    "tenant_rls_isolation":"PASS",
    "fail_closed_tenant_context":"PASS",
    "networking_permissions":"PASS"
  },
  "verified_at":datetime.datetime.now(datetime.timezone.utc).isoformat()
}
pathlib.Path(out).write_text(json.dumps(payload,indent=2)+"\n",encoding="utf-8")
print(json.dumps(payload,indent=2))
PY

echo "DOMAINS / PROXY ROUTES CONTRACT: PASS"
echo "receipt=$OUT/networking-db-receipt.json"
