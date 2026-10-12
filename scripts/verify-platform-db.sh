#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

IMAGE="${HCP_TEST_POSTGRES_IMAGE:-postgres:16-alpine}"
NAME="hcp-platform-db-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
UP="migrations/platform/000001_platform_foundation.up.sql"
DOWN="migrations/platform/000001_platform_foundation.down.sql"
OUT="$ROOT/.ci-out"

cleanup() {
  set +e
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

test -f "$UP"
test -f "$DOWN"
mkdir -p "$OUT"

echo "=== PLATFORM DB CONTRACT ==="
echo "image=$IMAGE"
echo "container=$NAME"

docker run -d   --name "$NAME"   -e POSTGRES_PASSWORD=hcp_ci_only   -e POSTGRES_DB=hcp_test   "$IMAGE" >/dev/null

ready=false
for _ in $(seq 1 45); do
  if docker exec "$NAME" pg_isready -U postgres -d hcp_test >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
if [[ "$ready" != "true" ]]; then
  docker logs "$NAME" || true
  echo "STOP: PostgreSQL did not become ready" >&2
  exit 1
fi

apply_up() {
  docker exec -i "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1 <"$UP"
}

apply_down() {
  docker exec -i "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1 <"$DOWN"
}

assert_schema() {
  docker exec -i "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1 <<'SQL'
DO $$
DECLARE
  table_count integer;
  migration_count integer;
BEGIN
  SELECT count(*) INTO table_count
  FROM information_schema.tables
  WHERE table_schema='hcp';

  IF table_count <> 8 THEN
    RAISE EXCEPTION 'expected 8 hcp tables, found %', table_count;
  END IF;

  SELECT count(*) INTO migration_count
  FROM hcp.schema_migrations
  WHERE version=1 AND name='platform_foundation';

  IF migration_count <> 1 THEN
    RAISE EXCEPTION 'platform migration receipt missing';
  END IF;
END $$;

INSERT INTO hcp.tenants(id, slug, display_name)
VALUES ('11111111-1111-1111-1111-111111111111', 'test-tenant', 'Test Tenant');

INSERT INTO hcp.nodes(id, name, status, agent_endpoint)
VALUES ('22222222-2222-2222-2222-222222222222', 'test-node', 'online', 'https://127.0.0.1.invalid');

INSERT INTO hcp.node_capabilities(node_id, capability, version)
VALUES ('22222222-2222-2222-2222-222222222222', 'container.inspect', '1');

INSERT INTO hcp.jobs(
  id, tenant_id, kind, status, resource_type, resource_id,
  idempotency_key, requested_by, input
) VALUES (
  '33333333-3333-3333-3333-333333333333',
  '11111111-1111-1111-1111-111111111111',
  'node.inspect', 'running', 'node',
  '22222222-2222-2222-2222-222222222222',
  'ci-idempotency-key', 'ci-verifier', '{"read_only":true}'::jsonb
);

INSERT INTO hcp.job_steps(job_id, ordinal, name, status)
VALUES ('33333333-3333-3333-3333-333333333333', 1, 'preflight', 'succeeded');

INSERT INTO hcp.job_events(job_id, event_type, payload)
VALUES ('33333333-3333-3333-3333-333333333333', 'job.started', '{"source":"ci"}'::jsonb);

INSERT INTO hcp.resource_locks(resource_type, resource_id, job_id, expires_at)
VALUES (
  'node',
  '22222222-2222-2222-2222-222222222222',
  '33333333-3333-3333-3333-333333333333',
  now() + interval '5 minutes'
);
SQL
}

echo
echo "=== APPLY UP ==="
apply_up
assert_schema
echo "PLATFORM DB APPLY: PASS"

echo
echo "=== CONSTRAINT GATES ==="
if docker exec "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1   -c "INSERT INTO hcp.tenants(id,slug,display_name,status) VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','bad-tenant','Bad','deleted');"   >/dev/null 2>&1; then
  echo "STOP: invalid tenant status was accepted" >&2
  exit 1
fi

if docker exec "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1   -c "INSERT INTO hcp.jobs(id,tenant_id,kind,status,idempotency_key,requested_by,completed_at) VALUES ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','11111111-1111-1111-1111-111111111111','test','succeeded','ci-idempotency-key','ci',now());"   >/dev/null 2>&1; then
  echo "STOP: duplicate idempotency key was accepted" >&2
  exit 1
fi
echo "PLATFORM DB CONSTRAINTS: PASS"

echo
echo "=== DOWN / REAPPLY ==="
apply_down
schema_exists="$(docker exec "$NAME" psql -U postgres -d hcp_test -Atc "SELECT count(*) FROM information_schema.schemata WHERE schema_name='hcp';")"
[[ "$schema_exists" == "0" ]] || { echo "STOP: hcp schema remains after down migration" >&2; exit 1; }
echo "PLATFORM DB DOWN: PASS"

apply_up
docker exec "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1   -c "SELECT version,name FROM hcp.schema_migrations ORDER BY version;" >/dev/null
echo "PLATFORM DB REAPPLY: PASS"

commit="${GITHUB_SHA:-local}"
run_id="${GITHUB_RUN_ID:-local}"
image_id="$(docker image inspect "$IMAGE" --format '{{.Id}}')"

python3 - "$OUT/platform-db-receipt.json" "$commit" "$run_id" "$IMAGE" "$image_id" <<'PY'
import datetime,json,pathlib,sys
out,commit,run_id,image,image_id=sys.argv[1:]
payload={
  "schema_version":1,
  "verification":"platform-db-foundation",
  "commit":commit,
  "run_id":run_id,
  "postgres_image":image,
  "postgres_image_id":image_id,
  "production_database_access":False,
  "checks":{
    "migration_up":"PASS",
    "schema_contract":"PASS",
    "constraints":"PASS",
    "migration_down":"PASS",
    "migration_reapply":"PASS"
  },
  "verified_at":datetime.datetime.now(datetime.timezone.utc).isoformat()
}
pathlib.Path(out).write_text(json.dumps(payload,indent=2)+"\n",encoding="utf-8")
print(json.dumps(payload,indent=2))
PY

echo
echo "PLATFORM DB CONTRACT: PASS"
echo "receipt=$OUT/platform-db-receipt.json"
