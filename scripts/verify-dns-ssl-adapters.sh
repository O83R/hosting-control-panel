#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

IMAGE="$(printenv HCP_TEST_POSTGRES_IMAGE || true)"
if [ -z "$IMAGE" ]; then
  IMAGE="postgres:16-alpine"
fi
RUN_ID="$(printenv GITHUB_RUN_ID || true)"
if [ -z "$RUN_ID" ]; then
  RUN_ID="local"
fi
RUN_ATTEMPT="$(printenv GITHUB_RUN_ATTEMPT || true)"
if [ -z "$RUN_ATTEMPT" ]; then
  RUN_ATTEMPT="1"
fi

NAME="hcp-dns-ssl-$RUN_ID-$RUN_ATTEMPT"
MIGRATIONS="$ROOT/migrations/platform"
OUT="$ROOT/.ci-out"

cleanup() {
  set +e
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$OUT"

echo "=== DNS / SSL ADAPTER CONTRACT ==="

if grep -R -n -E 'net/http|http\.Client|http\.NewRequest|\.Do\(' internal/adapters/dns internal/adapters/certificates; then
  echo "STOP: provider adapter contains direct outbound HTTP execution" >&2
  exit 1
fi
echo "NO OUTBOUND PROVIDER EXECUTION: PASS"

go test ./internal/adapters/dns ./internal/adapters/certificates
echo "PROVIDER ADAPTER UNIT TESTS: PASS"

MIGRATION_COUNT="$(find "$MIGRATIONS" -maxdepth 1 -type f -name '*.up.sql' | wc -l | tr -d ' ')"
if [ "$MIGRATION_COUNT" -lt 7 ]; then
  echo "STOP: DNS/SSL migration chain incomplete" >&2
  exit 1
fi

docker run -d \
  --name "$NAME" \
  -e POSTGRES_PASSWORD=hcp_ci_only \
  -e POSTGRES_DB=hcp_test \
  "$IMAGE" >/dev/null

stable=0
for _ in $(seq 1 60); do
  if docker exec "$NAME" psql -U postgres -d hcp_test -Atqc 'SELECT 1;' >/dev/null 2>&1; then
    stable=$((stable + 1))
    if [ "$stable" -ge 3 ]; then
      break
    fi
  else
    stable=0
  fi
  sleep 1
done
if [ "$stable" -lt 3 ]; then
  docker logs "$NAME" || true
  echo "STOP: PostgreSQL not stably ready" >&2
  exit 1
fi

for migration in "$MIGRATIONS"/*.up.sql; do
  docker exec -i "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1 <"$migration"
done

docker exec -i "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO hcp.tenants(id, slug, display_name) VALUES
  ('71000000-0000-0000-0000-000000000001', 'dns-one', 'DNS One'),
  ('71000000-0000-0000-0000-000000000002', 'dns-two', 'DNS Two');

INSERT INTO hcp.users(id, username) VALUES
  ('72000000-0000-0000-0000-000000000001', 'dns-owner-one'),
  ('72000000-0000-0000-0000-000000000002', 'dns-owner-two');

INSERT INTO hcp.tenant_memberships(tenant_id, user_id) VALUES
  ('71000000-0000-0000-0000-000000000001', '72000000-0000-0000-0000-000000000001'),
  ('71000000-0000-0000-0000-000000000002', '72000000-0000-0000-0000-000000000002');

INSERT INTO hcp.hosting_packages(
  id, tenant_id, code, display_name, max_sites, max_domains, max_databases, storage_mb
) VALUES
  ('73000000-0000-0000-0000-000000000001', '71000000-0000-0000-0000-000000000001', 'dns-plan-one', 'DNS Plan One', 2, 2, 1, 1024),
  ('73000000-0000-0000-0000-000000000002', '71000000-0000-0000-0000-000000000002', 'dns-plan-two', 'DNS Plan Two', 1, 1, 1, 1024);

INSERT INTO hcp.hosting_accounts(
  id, tenant_id, package_id, owner_user_id, account_key, display_name
) VALUES
  ('74000000-0000-0000-0000-000000000001', '71000000-0000-0000-0000-000000000001', '73000000-0000-0000-0000-000000000001', '72000000-0000-0000-0000-000000000001', 'dns-account-one', 'DNS Account One'),
  ('74000000-0000-0000-0000-000000000002', '71000000-0000-0000-0000-000000000002', '73000000-0000-0000-0000-000000000002', '72000000-0000-0000-0000-000000000002', 'dns-account-two', 'DNS Account Two');

INSERT INTO hcp.sites(
  id, tenant_id, account_id, site_key, display_name, kind, origin
) VALUES
  ('75000000-0000-0000-0000-000000000001', '71000000-0000-0000-0000-000000000001', '74000000-0000-0000-0000-000000000001', 'dns-site-one', 'DNS Site One', 'containerized', 'managed'),
  ('75000000-0000-0000-0000-000000000002', '71000000-0000-0000-0000-000000000002', '74000000-0000-0000-0000-000000000002', 'dns-site-two', 'DNS Site Two', 'containerized', 'managed');

UPDATE hcp.sites
SET status='active'
WHERE id IN (
  '75000000-0000-0000-0000-000000000001',
  '75000000-0000-0000-0000-000000000002'
);

INSERT INTO hcp.domains(id, tenant_id, site_id, fqdn, dns_mode, ssl_mode) VALUES
  ('76000000-0000-0000-0000-000000000001', '71000000-0000-0000-0000-000000000001', '75000000-0000-0000-0000-000000000001', 'app.example.test', 'managed', 'automatic'),
  ('76000000-0000-0000-0000-000000000002', '71000000-0000-0000-0000-000000000001', '75000000-0000-0000-0000-000000000001', 'legacy.example.net', 'external', 'manual');

UPDATE hcp.domains
SET verification_status='pending'
WHERE id='76000000-0000-0000-0000-000000000001';

UPDATE hcp.domains
SET verification_status='verified'
WHERE id='76000000-0000-0000-0000-000000000001';

UPDATE hcp.domains
SET status='active'
WHERE id='76000000-0000-0000-0000-000000000001';

INSERT INTO hcp.dns_provider_bindings(
  id, tenant_id, provider_type, mode, zone_name, provider_zone_ref, credential_ref
) VALUES
  (
    '77000000-0000-0000-0000-000000000001',
    '71000000-0000-0000-0000-000000000001',
    'cloudflare', 'managed', 'example.test', 'zone-ci-1', 'secretref://cloudflare/ci'
  ),
  (
    '77000000-0000-0000-0000-000000000002',
    '71000000-0000-0000-0000-000000000001',
    'external', 'read_only', 'example.net', 'external-zone-ci', NULL
  );

INSERT INTO hcp.dns_records(
  id, tenant_id, domain_id, binding_id,
  record_type, name, content, ttl, management_mode, status
) VALUES
  (
    '78000000-0000-0000-0000-000000000001',
    '71000000-0000-0000-0000-000000000001',
    '76000000-0000-0000-0000-000000000001',
    '77000000-0000-0000-0000-000000000001',
    'A', 'app.example.test', '192.0.2.10', 300, 'desired', 'pending'
  ),
  (
    '78000000-0000-0000-0000-000000000002',
    '71000000-0000-0000-0000-000000000001',
    '76000000-0000-0000-0000-000000000002',
    '77000000-0000-0000-0000-000000000002',
    'TXT', 'legacy.example.net', 'observed-ci', 300, 'observed', 'observed'
  );

INSERT INTO hcp.certificates(
  id, tenant_id, domain_id, provider_type, challenge_type, status
) VALUES (
  '79000000-0000-0000-0000-000000000001',
  '71000000-0000-0000-0000-000000000001',
  '76000000-0000-0000-0000-000000000001',
  'acme', 'dns-01', 'pending'
);

UPDATE hcp.certificates
SET status='issuing'
WHERE id='79000000-0000-0000-0000-000000000001';

UPDATE hcp.certificates
SET status='active',
    certificate_ref='secretref://certificates/ci/cert',
    private_key_ref='secretref://certificates/ci/key',
    issuer_name='CI ACME',
    serial_number='CI-001',
    not_before=now() - interval '1 minute',
    not_after=now() + interval '90 days',
    renew_after=now() + interval '60 days'
WHERE id='79000000-0000-0000-0000-000000000001';
SQL

echo "MANAGED/READONLY DNS + CERTIFICATE LIFECYCLE: PASS"

if docker exec "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1 \
  -c "INSERT INTO hcp.dns_records(id,tenant_id,domain_id,binding_id,record_type,name,content,ttl,management_mode,status) VALUES ('78000000-0000-0000-0000-000000000003','71000000-0000-0000-0000-000000000001','76000000-0000-0000-0000-000000000002','77000000-0000-0000-0000-000000000002','A','legacy.example.net','192.0.2.20',300,'desired','pending');" \
  >/dev/null 2>&1; then
  echo "STOP: read-only DNS binding accepted desired mutation" >&2
  exit 1
fi

if docker exec "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1 \
  -c "INSERT INTO hcp.dns_records(id,tenant_id,domain_id,binding_id,record_type,name,content,ttl,management_mode,status) VALUES ('78000000-0000-0000-0000-000000000004','71000000-0000-0000-0000-000000000001','76000000-0000-0000-0000-000000000001','77000000-0000-0000-0000-000000000001','TXT','outside.example.org','bad',300,'desired','pending');" \
  >/dev/null 2>&1; then
  echo "STOP: DNS record outside provider zone was accepted" >&2
  exit 1
fi

if docker exec "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1 \
  -c "INSERT INTO hcp.dns_provider_bindings(id,tenant_id,provider_type,mode,zone_name,provider_zone_ref,credential_ref) VALUES ('77000000-0000-0000-0000-000000000003','71000000-0000-0000-0000-000000000001','external','managed','bad.example.test','z','secretref://bad');" \
  >/dev/null 2>&1; then
  echo "STOP: external provider accepted managed credential binding" >&2
  exit 1
fi

echo "DNS PROVIDER SAFETY GATES: PASS"

for forbidden in api_token token secret private_key certificate_pem private_key_pem; do
  count="$(docker exec "$NAME" psql -U postgres -d hcp_test -Atc "SELECT count(*) FROM information_schema.columns WHERE table_schema='hcp' AND table_name IN ('dns_provider_bindings','dns_records','certificates') AND column_name='$forbidden';")"
  if [ "$count" != "0" ]; then
    echo "STOP: forbidden raw secret column present: $forbidden" >&2
    exit 1
  fi
done
echo "NO RAW SECRET COLUMNS: PASS"

docker exec -i "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1 <<'SQL'
CREATE ROLE hcp_ci_dns_ssl NOLOGIN;
GRANT USAGE ON SCHEMA hcp TO hcp_ci_dns_ssl;
GRANT SELECT ON hcp.dns_provider_bindings, hcp.dns_records, hcp.certificates TO hcp_ci_dns_ssl;

SET ROLE hcp_ci_dns_ssl;
SET hcp.scope = 'tenant';
SET hcp.tenant_id = '71000000-0000-0000-0000-000000000001';

DO $$
DECLARE
  bindings_seen integer;
  records_seen integer;
  certs_seen integer;
BEGIN
  SELECT count(*) INTO bindings_seen FROM hcp.dns_provider_bindings;
  SELECT count(*) INTO records_seen FROM hcp.dns_records;
  SELECT count(*) INTO certs_seen FROM hcp.certificates;
  IF bindings_seen <> 2 THEN RAISE EXCEPTION 'binding RLS mismatch: %', bindings_seen; END IF;
  IF records_seen <> 2 THEN RAISE EXCEPTION 'record RLS mismatch: %', records_seen; END IF;
  IF certs_seen <> 1 THEN RAISE EXCEPTION 'certificate RLS mismatch: %', certs_seen; END IF;
END $$;

RESET hcp.tenant_id;
DO $$
DECLARE
  total_seen integer;
BEGIN
  SELECT
    (SELECT count(*) FROM hcp.dns_provider_bindings)
    + (SELECT count(*) FROM hcp.dns_records)
    + (SELECT count(*) FROM hcp.certificates)
  INTO total_seen;
  IF total_seen <> 0 THEN
    RAISE EXCEPTION 'DNS/SSL tenant context did not fail closed';
  END IF;
END $$;

RESET ROLE;
SQL

echo "DNS/SSL RLS ISOLATION: PASS"
echo "DNS/SSL FAIL-CLOSED CONTEXT: PASS"

permissions_count="$(docker exec "$NAME" psql -U postgres -d hcp_test -Atc "SELECT count(*) FROM hcp.permissions WHERE code IN ('dns.read','dns.manage','ssl.read','ssl.manage');")"
if [ "$permissions_count" != "4" ]; then
  echo "STOP: DNS/SSL permission contract failed" >&2
  exit 1
fi

commit="$(printenv GITHUB_SHA || true)"
if [ -z "$commit" ]; then
  commit="local"
fi
run_id="$RUN_ID"
image_id="$(docker image inspect "$IMAGE" --format '{{.Id}}')"

python3 - "$OUT/dns-ssl-adapters-receipt.json" "$commit" "$run_id" "$IMAGE" "$image_id" <<'PY'
import datetime,json,pathlib,sys
out,commit,run_id,image,image_id=sys.argv[1:]
payload={
  "schema_version":1,
  "verification":"dns-ssl-provider-adapters",
  "commit":commit,
  "run_id":run_id,
  "postgres_image":image,
  "postgres_image_id":image_id,
  "production_database_access":False,
  "production_mutation":False,
  "provider_network_access":False,
  "checks":{
    "cloudflare_request_planning":"PASS",
    "external_dns_read_only":"PASS",
    "acme_order_planning":"PASS",
    "no_outbound_provider_execution":"PASS",
    "managed_readonly_dns_contract":"PASS",
    "certificate_lifecycle":"PASS",
    "no_raw_secret_columns":"PASS",
    "tenant_rls_isolation":"PASS",
    "fail_closed_tenant_context":"PASS"
  },
  "verified_at":datetime.datetime.now(datetime.timezone.utc).isoformat()
}
pathlib.Path(out).write_text(json.dumps(payload,indent=2)+"\n",encoding="utf-8")
print(json.dumps(payload,indent=2))
PY

echo "DNS / SSL ADAPTER CONTRACT: PASS"
echo "receipt=$OUT/dns-ssl-adapters-receipt.json"
