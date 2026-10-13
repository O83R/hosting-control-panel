#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

IMAGE="${HCP_TEST_POSTGRES_IMAGE:-postgres:16-alpine}"
NAME="hcp-sites-db-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
MIGRATIONS="$ROOT/migrations/platform"
OUT="$ROOT/.ci-out"

cleanup() {
  set +e
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$OUT"
mapfile -t UPS < <(find "$MIGRATIONS" -maxdepth 1 -type f -name '*.up.sql' | sort)
[ "${#UPS[@]}" -ge 5 ] || { echo "STOP: sites/adoption migration chain incomplete" >&2; exit 1; }

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
  ('51000000-0000-0000-0000-000000000001', 'sites-one', 'Sites One'),
  ('51000000-0000-0000-0000-000000000002', 'sites-two', 'Sites Two');

INSERT INTO hcp.users(id, username) VALUES
  ('52000000-0000-0000-0000-000000000001', 'sites-owner-one'),
  ('52000000-0000-0000-0000-000000000002', 'sites-owner-two');

INSERT INTO hcp.tenant_memberships(tenant_id, user_id) VALUES
  ('51000000-0000-0000-0000-000000000001', '52000000-0000-0000-0000-000000000001'),
  ('51000000-0000-0000-0000-000000000002', '52000000-0000-0000-0000-000000000002');

INSERT INTO hcp.nodes(id, name, status) VALUES
  ('53000000-0000-0000-0000-000000000001', 'sites-node-01', 'online');

INSERT INTO hcp.hosting_packages(
  id, tenant_id, code, display_name,
  max_sites, max_domains, max_databases, storage_mb
) VALUES
  (
    '54000000-0000-0000-0000-000000000001',
    '51000000-0000-0000-0000-000000000001',
    'single-site', 'Single Site', 1, 2, 1, 1024
  ),
  (
    '54000000-0000-0000-0000-000000000002',
    '51000000-0000-0000-0000-000000000002',
    'tenant-two', 'Tenant Two', 2, 2, 1, 1024
  );

INSERT INTO hcp.hosting_accounts(
  id, tenant_id, package_id, owner_user_id, node_id,
  account_key, display_name
) VALUES
  (
    '55000000-0000-0000-0000-000000000001',
    '51000000-0000-0000-0000-000000000001',
    '54000000-0000-0000-0000-000000000001',
    '52000000-0000-0000-0000-000000000001',
    '53000000-0000-0000-0000-000000000001',
    'account-one', 'Account One'
  ),
  (
    '55000000-0000-0000-0000-000000000002',
    '51000000-0000-0000-0000-000000000002',
    '54000000-0000-0000-0000-000000000002',
    '52000000-0000-0000-0000-000000000002',
    '53000000-0000-0000-0000-000000000001',
    'account-two', 'Account Two'
  );

INSERT INTO hcp.sites(
  id, tenant_id, account_id, node_id,
  site_key, display_name, kind, origin
) VALUES (
  '56000000-0000-0000-0000-000000000001',
  '51000000-0000-0000-0000-000000000001',
  '55000000-0000-0000-0000-000000000001',
  '53000000-0000-0000-0000-000000000001',
  'portal-one', 'Portal One', 'containerized', 'managed'
);

UPDATE hcp.sites
SET status='active'
WHERE id='56000000-0000-0000-0000-000000000001';

UPDATE hcp.sites
SET status='suspended'
WHERE id='56000000-0000-0000-0000-000000000001';

UPDATE hcp.sites
SET status='active'
WHERE id='56000000-0000-0000-0000-000000000001';

INSERT INTO hcp.site_adoption_candidates(
  id, tenant_id, node_id, external_ref,
  display_name, runtime_kind, fingerprint, observed_state
) VALUES (
  '57000000-0000-0000-0000-000000000001',
  '51000000-0000-0000-0000-000000000001',
  '53000000-0000-0000-0000-000000000001',
  'compose:legacy-portal',
  'Legacy Portal',
  'containerized',
  'sha256:ci-fingerprint-one',
  '{"mode":"read_only_discovery"}'::jsonb
);

UPDATE hcp.site_adoption_candidates
SET status='reviewed'
WHERE id='57000000-0000-0000-0000-000000000001';

UPDATE hcp.sites
SET status='disabled'
WHERE id='56000000-0000-0000-0000-000000000001';

INSERT INTO hcp.sites(
  id, tenant_id, account_id, node_id,
  site_key, display_name, kind, origin, source_ref
) VALUES (
  '56000000-0000-0000-0000-000000000002',
  '51000000-0000-0000-0000-000000000001',
  '55000000-0000-0000-0000-000000000001',
  '53000000-0000-0000-0000-000000000001',
  'legacy-portal', 'Legacy Portal', 'containerized', 'adopted',
  'compose:legacy-portal'
);

UPDATE hcp.sites
SET status='active'
WHERE id='56000000-0000-0000-0000-000000000002';

UPDATE hcp.site_adoption_candidates
SET status='adopted',
    adopted_site_id='56000000-0000-0000-0000-000000000002'
WHERE id='57000000-0000-0000-0000-000000000001';
SQL

echo "SITE LIFECYCLE / ADOPTION: PASS"

if docker exec "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1   -c "INSERT INTO hcp.sites(id,tenant_id,account_id,site_key,display_name,kind,origin) VALUES ('56000000-0000-0000-0000-000000000003','51000000-0000-0000-0000-000000000001','55000000-0000-0000-0000-000000000001','quota-exceeded','Quota Exceeded','static','managed');"   >/dev/null 2>&1; then
  echo "STOP: package max_sites quota was not enforced" >&2
  exit 1
fi

if docker exec "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1   -c "INSERT INTO hcp.sites(id,tenant_id,account_id,site_key,display_name,kind,origin) VALUES ('56000000-0000-0000-0000-000000000004','51000000-0000-0000-0000-000000000001','55000000-0000-0000-0000-000000000002','cross-tenant','Cross Tenant','static','managed');"   >/dev/null 2>&1; then
  echo "STOP: cross-tenant account/site assignment accepted" >&2
  exit 1
fi

if docker exec "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1   -c "UPDATE hcp.sites SET status='active' WHERE id='56000000-0000-0000-0000-000000000001';"   >/dev/null 2>&1; then
  echo "STOP: disabled site reactivated" >&2
  exit 1
fi

echo "SITE QUOTA / TENANT / TERMINAL GATES: PASS"

docker exec -i "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1 <<'SQL'
CREATE ROLE hcp_ci_sites NOLOGIN;
GRANT USAGE ON SCHEMA hcp TO hcp_ci_sites;
GRANT SELECT ON hcp.sites, hcp.site_adoption_candidates TO hcp_ci_sites;

SET ROLE hcp_ci_sites;
SET hcp.scope = 'tenant';
SET hcp.tenant_id = '51000000-0000-0000-0000-000000000001';

DO $$
DECLARE
  sites_seen integer;
  candidates_seen integer;
BEGIN
  SELECT count(*) INTO sites_seen FROM hcp.sites;
  SELECT count(*) INTO candidates_seen FROM hcp.site_adoption_candidates;
  IF sites_seen <> 2 THEN RAISE EXCEPTION 'site RLS mismatch: %', sites_seen; END IF;
  IF candidates_seen <> 1 THEN RAISE EXCEPTION 'adoption RLS mismatch: %', candidates_seen; END IF;
END $$;

RESET hcp.tenant_id;
DO $$
DECLARE
  sites_seen integer;
  candidates_seen integer;
BEGIN
  SELECT count(*) INTO sites_seen FROM hcp.sites;
  SELECT count(*) INTO candidates_seen FROM hcp.site_adoption_candidates;
  IF sites_seen <> 0 OR candidates_seen <> 0 THEN
    RAISE EXCEPTION 'site/adoption tenant context did not fail closed';
  END IF;
END $$;

RESET ROLE;
SQL

echo "SITE/ADOPTION RLS: PASS"
echo "SITE/ADOPTION FAIL-CLOSED CONTEXT: PASS"

commit="${GITHUB_SHA:-local}"
run_id="${GITHUB_RUN_ID:-local}"
image_id="$(docker image inspect "$IMAGE" --format '{{.Id}}')"

python3 - "$OUT/sites-db-receipt.json" "$commit" "$run_id" "$IMAGE" "$image_id" <<'PY'
import datetime,json,pathlib,sys
out,commit,run_id,image,image_id=sys.argv[1:]
payload={
  "schema_version":1,
  "verification":"sites-adoption",
  "commit":commit,
  "run_id":run_id,
  "postgres_image":image,
  "postgres_image_id":image_id,
  "production_database_access":False,
  "production_mutation":False,
  "checks":{
    "site_model":"PASS",
    "site_lifecycle":"PASS",
    "package_site_quota":"PASS",
    "cross_tenant_account_rejection":"PASS",
    "adoption_workflow":"PASS",
    "tenant_rls_isolation":"PASS",
    "fail_closed_tenant_context":"PASS"
  },
  "verified_at":datetime.datetime.now(datetime.timezone.utc).isoformat()
}
pathlib.Path(out).write_text(json.dumps(payload,indent=2)+"\n",encoding="utf-8")
print(json.dumps(payload,indent=2))
PY

echo "SITES / ADOPTION CONTRACT: PASS"
echo "receipt=$OUT/sites-db-receipt.json"
