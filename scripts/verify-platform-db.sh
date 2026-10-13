#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

IMAGE="${HCP_TEST_POSTGRES_IMAGE:-postgres:16-alpine}"
NAME="hcp-platform-db-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
MIGRATIONS="$ROOT/migrations/platform"
OUT="$ROOT/.ci-out"

cleanup() {
  set +e
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$OUT"

mapfile -t UPS < <(find "$MIGRATIONS" -maxdepth 1 -type f -name '*.up.sql' | sort)
mapfile -t DOWNS < <(find "$MIGRATIONS" -maxdepth 1 -type f -name '*.down.sql' | sort -r)

(("${#UPS[@]}" > 0)) || { echo "STOP: no platform up migrations found" >&2; exit 1; }
[ "${#UPS[@]}" -eq "${#DOWNS[@]}" ] || { echo "STOP: up/down migration count mismatch" >&2; exit 1; }

for up in "${UPS[@]}"; do
  test -f "${up%.up.sql}.down.sql" || { echo "STOP: missing down migration for $up" >&2; exit 1; }
done

echo "=== PLATFORM DB CONTRACT ==="
echo "image=$IMAGE"
echo "container=$NAME"
echo "migration_count=${#UPS[@]}"

docker run -d   --name "$NAME"   -e POSTGRES_PASSWORD=hcp_ci_only   -e POSTGRES_DB=hcp_test   "$IMAGE" >/dev/null

ready=false
stable_checks=0
for _ in $(seq 1 60); do
  if docker exec "$NAME" psql -U postgres -d hcp_test -Atqc 'SELECT 1;' >/dev/null 2>&1; then
    stable_checks=$((stable_checks + 1))
    if (( stable_checks >= 3 )); then
      ready=true
      break
    fi
  else
    stable_checks=0
  fi
  sleep 1
done
[[ "$ready" == "true" ]] || { docker logs "$NAME" || true; echo "STOP: PostgreSQL did not become stably ready" >&2; exit 1; }
echo "POSTGRES STABLE READINESS: PASS"

apply_up() {
  for migration in "${UPS[@]}"; do
    echo "apply_up=$(basename "$migration")"
    docker exec -i "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1 <"$migration"
  done
}

apply_down() {
  for migration in "${DOWNS[@]}"; do
    echo "apply_down=$(basename "$migration")"
    docker exec -i "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1 <"$migration"
  done
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
  WHERE table_schema='hcp'
    AND table_name IN (
      'schema_migrations',
      'tenants',
      'nodes',
      'node_capabilities',
      'jobs',
      'job_steps',
      'job_events',
      'resource_locks'
    );
  IF table_count <> 8 THEN
    RAISE EXCEPTION 'required platform foundation tables missing: found % of 8', table_count;
  END IF;

  SELECT count(*) INTO migration_count FROM hcp.schema_migrations;
  IF migration_count < 2 THEN
    RAISE EXCEPTION 'expected at least 2 migration receipts, found %', migration_count;
  END IF;
END $$;

INSERT INTO hcp.tenants(id, slug, display_name)
VALUES ('11111111-1111-1111-1111-111111111111', 'test-tenant', 'Test Tenant');

INSERT INTO hcp.nodes(id, name, status, agent_endpoint)
VALUES ('22222222-2222-2222-2222-222222222222', 'test-node', 'online', 'https://127.0.0.1.invalid');

INSERT INTO hcp.node_capabilities(node_id, capability, version)
VALUES ('22222222-2222-2222-2222-222222222222', 'container.inspect', '1');

INSERT INTO hcp.jobs(id, tenant_id, kind, status, resource_type, resource_id, idempotency_key, requested_by, input)
VALUES (
  '33333333-3333-3333-3333-333333333333',
  '11111111-1111-1111-1111-111111111111',
  'node.inspect', 'queued', 'node',
  '22222222-2222-2222-2222-222222222222',
  'ci-idempotency-key', 'ci-verifier', '{"read_only":true}'::jsonb
);

UPDATE hcp.jobs
SET status='running'
WHERE id='33333333-3333-3333-3333-333333333333';

DO $$
DECLARE
  v bigint;
  started timestamptz;
BEGIN
  SELECT version, started_at INTO v, started
  FROM hcp.jobs
  WHERE id='33333333-3333-3333-3333-333333333333';
  IF v <> 2 OR started IS NULL THEN
    RAISE EXCEPTION 'queued -> running transition contract failed';
  END IF;
END $$;

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

UPDATE hcp.jobs
SET status='succeeded', output='{"verified":true}'::jsonb
WHERE id='33333333-3333-3333-3333-333333333333';

DO $$
DECLARE
  v bigint;
  completed timestamptz;
BEGIN
  SELECT version, completed_at INTO v, completed
  FROM hcp.jobs
  WHERE id='33333333-3333-3333-3333-333333333333';
  IF v <> 3 OR completed IS NULL THEN
    RAISE EXCEPTION 'running -> succeeded transition contract failed';
  END IF;
END $$;
SQL
}

echo
echo "=== APPLY MIGRATION CHAIN ==="
apply_up
migration_count="$(docker exec "$NAME" psql -U postgres -d hcp_test -Atc "SELECT count(*) FROM hcp.schema_migrations;")"
[[ "$migration_count" == "${#UPS[@]}" ]] || {
  echo "STOP: applied migration receipt count is $migration_count, expected ${#UPS[@]}" >&2
  exit 1
}
assert_schema
echo "PLATFORM DB APPLY: PASS"

echo
echo "=== CONSTRAINT / STATE GATES ==="
if docker exec "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1   -c "INSERT INTO hcp.tenants(id,slug,display_name,status) VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','bad-tenant','Bad','deleted');"   >/dev/null 2>&1; then
  echo "STOP: invalid tenant status was accepted" >&2
  exit 1
fi

if docker exec "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1   -c "INSERT INTO hcp.jobs(id,tenant_id,kind,status,idempotency_key,requested_by) VALUES ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','11111111-1111-1111-1111-111111111111','test','queued','ci-idempotency-key','ci');"   >/dev/null 2>&1; then
  echo "STOP: duplicate tenant idempotency key was accepted" >&2
  exit 1
fi

docker exec "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1   -c "INSERT INTO hcp.jobs(id,kind,status,idempotency_key,requested_by) VALUES ('cccccccc-cccc-cccc-cccc-cccccccccccc','system.inspect','queued','global-ci-key','ci');" >/dev/null

if docker exec "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1   -c "INSERT INTO hcp.jobs(id,kind,status,idempotency_key,requested_by) VALUES ('dddddddd-dddd-dddd-dddd-dddddddddddd','system.inspect','queued','global-ci-key','ci');"   >/dev/null 2>&1; then
  echo "STOP: duplicate global idempotency key was accepted" >&2
  exit 1
fi

if docker exec "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1   -c "UPDATE hcp.jobs SET status='running' WHERE id='33333333-3333-3333-3333-333333333333';"   >/dev/null 2>&1; then
  echo "STOP: terminal -> running transition was accepted" >&2
  exit 1
fi

echo "PLATFORM DB CONSTRAINTS: PASS"
echo "PLATFORM DB JOB STATE MACHINE: PASS"

echo
echo "=== DOWN / CLEAN REAPPLY ==="
apply_down
schema_exists="$(docker exec "$NAME" psql -U postgres -d hcp_test -Atc "SELECT count(*) FROM information_schema.schemata WHERE schema_name='hcp';")"
[[ "$schema_exists" == "0" ]] || { echo "STOP: hcp schema remains after down migrations" >&2; exit 1; }
echo "PLATFORM DB DOWN: PASS"

apply_up
migration_count="$(docker exec "$NAME" psql -U postgres -d hcp_test -Atc "SELECT count(*) FROM hcp.schema_migrations;")"
[[ "$migration_count" == "${#UPS[@]}" ]] || { echo "STOP: reapply migration receipt count is $migration_count, expected ${#UPS[@]}" >&2; exit 1; }
echo "PLATFORM DB REAPPLY: PASS"

commit="${GITHUB_SHA:-local}"
run_id="${GITHUB_RUN_ID:-local}"
image_id="$(docker image inspect "$IMAGE" --format '{{.Id}}')"

python3 - "$OUT/platform-db-receipt.json" "$commit" "$run_id" "$IMAGE" "$image_id" "$migration_count" <<'PY'
import datetime,json,pathlib,sys
out,commit,run_id,image,image_id,migration_count=sys.argv[1:]
payload={
  "schema_version":1,
  "verification":"platform-db-foundation",
  "commit":commit,
  "run_id":run_id,
  "postgres_image":image,
  "postgres_image_id":image_id,
  "migration_count":int(migration_count),
  "production_database_access":False,
  "checks":{
    "migration_chain_up":"PASS",
    "schema_contract":"PASS",
    "constraints":"PASS",
    "job_state_machine":"PASS",
    "tenant_idempotency":"PASS",
    "global_idempotency":"PASS",
    "migration_chain_down":"PASS",
    "migration_chain_reapply":"PASS"
  },
  "verified_at":datetime.datetime.now(datetime.timezone.utc).isoformat()
}
pathlib.Path(out).write_text(json.dumps(payload,indent=2)+"\n",encoding="utf-8")
print(json.dumps(payload,indent=2))
PY

echo
echo "PLATFORM DB CONTRACT: PASS"
echo "receipt=$OUT/platform-db-receipt.json"
