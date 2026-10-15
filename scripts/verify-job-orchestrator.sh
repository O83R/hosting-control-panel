#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

IMAGE="${HCP_TEST_POSTGRES_IMAGE:-postgres:16-alpine}"
NAME="hcp-jobs-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
OUT="$ROOT/.ci-out"
mkdir -p "$OUT"
cleanup() {
  set +e
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== PHASE 08 ISOLATED JOB CONTRACT ==="
go test ./internal/jobs
echo "SYNTHETIC JOB INTENT TESTS: PASS"

# No host ports, production mounts, secrets, or network access.
docker run -d --name "$NAME" --network none \
  -e POSTGRES_PASSWORD=hcp_ci_only -e POSTGRES_DB=hcp_test "$IMAGE" >/dev/null

ready=false
for _ in $(seq 1 60); do
  if docker exec "$NAME" psql -U postgres -d hcp_test -Atqc 'SELECT 1;' >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
[[ "$ready" == "true" ]] || { echo "STOP: temporary PostgreSQL not ready" >&2; exit 1; }

for file in "$ROOT"/migrations/platform/*.up.sql; do
  docker exec -i "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1 < "$file" >/dev/null
done
echo "ISOLATED MIGRATION CHAIN: PASS"

docker exec -i "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1 <<'SQL'
DO $$
DECLARE
  isolation_count integer;
BEGIN
  SELECT count(*) INTO isolation_count
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname='hcp'
    AND c.relname IN ('jobs','job_steps','job_events','resource_locks')
    AND c.relrowsecurity AND c.relforcerowsecurity;
  IF isolation_count <> 4 THEN
    RAISE EXCEPTION 'job RLS/FORCE RLS expected 4, got %', isolation_count;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='hcp' AND table_name='jobs'
      AND column_name='intent_fingerprint'
  ) THEN
    RAISE EXCEPTION 'missing intent_fingerprint';
  END IF;
END $$;

INSERT INTO hcp.tenants(id,slug,display_name)
VALUES
('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','tenant-one','Tenant One'),
('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','tenant-two','Tenant Two');

INSERT INTO hcp.jobs(id,tenant_id,kind,requested_by)
VALUES
('cccccccc-cccc-cccc-cccc-cccccccccccc','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','agent.ping','ci'),
('dddddddd-dddd-dddd-dddd-dddddddddddd','bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','agent.ping','ci'),
('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee',NULL,'system.inspect','ci');

INSERT INTO hcp.job_steps(job_id,ordinal,name)
VALUES
('cccccccc-cccc-cccc-cccc-cccccccccccc',1,'preflight'),
('dddddddd-dddd-dddd-dddd-dddddddddddd',1,'preflight'),
('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee',1,'preflight');

INSERT INTO hcp.job_events(job_id,event_type)
VALUES
('cccccccc-cccc-cccc-cccc-cccccccccccc','job.queued'),
('dddddddd-dddd-dddd-dddd-dddddddddddd','job.queued'),
('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee','job.queued');

INSERT INTO hcp.resource_locks(resource_type,resource_id,job_id,expires_at)
VALUES
('node','node-ci-one','cccccccc-cccc-cccc-cccc-cccccccccccc',now()+interval '1 hour'),
('node','node-ci-two','dddddddd-dddd-dddd-dddd-dddddddddddd',now()+interval '1 hour'),
('node','node-ci-system','eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee',now()+interval '1 hour');

CREATE ROLE hcp_jobs_reader NOLOGIN;
GRANT USAGE ON SCHEMA hcp TO hcp_jobs_reader;
GRANT SELECT ON hcp.jobs,hcp.job_steps,hcp.job_events,hcp.resource_locks TO hcp_jobs_reader;
-- INSERT is granted only in the disposable CI database to test WITH CHECK.
GRANT INSERT ON hcp.jobs TO hcp_jobs_reader;

SET ROLE hcp_jobs_reader;
SET hcp.scope = 'tenant';
SET hcp.tenant_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

DO $$
BEGIN
  IF (SELECT count(*) FROM hcp.jobs) <> 1 OR
     (SELECT count(*) FROM hcp.job_steps) <> 1 OR
     (SELECT count(*) FROM hcp.job_events) <> 1 OR
     (SELECT count(*) FROM hcp.resource_locks) <> 1 THEN
    RAISE EXCEPTION 'tenant-one child/parent isolation failed';
  END IF;
END $$;

SET hcp.tenant_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
DO $$
BEGIN
  IF (SELECT count(*) FROM hcp.jobs) <> 1 OR
     (SELECT count(*) FROM hcp.job_steps) <> 1 OR
     (SELECT count(*) FROM hcp.job_events) <> 1 OR
     (SELECT count(*) FROM hcp.resource_locks) <> 1 THEN
    RAISE EXCEPTION 'tenant-two child/parent isolation failed';
  END IF;
END $$;

-- A tenant context cannot write into another tenant's job scope.
DO $$
BEGIN
  BEGIN
    INSERT INTO hcp.jobs(id,tenant_id,kind,requested_by)
    VALUES ('ffffffff-ffff-ffff-ffff-ffffffffffff',
            'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','agent.ping','ci');
    RAISE EXCEPTION 'cross-tenant write was accepted';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END $$;

RESET hcp.tenant_id;
DO $$
BEGIN
  IF (SELECT count(*) FROM hcp.jobs) <> 0 OR
     (SELECT count(*) FROM hcp.job_steps) <> 0 OR
     (SELECT count(*) FROM hcp.job_events) <> 0 OR
     (SELECT count(*) FROM hcp.resource_locks) <> 0 THEN
    RAISE EXCEPTION 'missing tenant context must fail closed';
  END IF;
END $$;

SET hcp.scope = 'platform';
SET hcp.tenant_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
DO $$
BEGIN
  IF (SELECT count(*) FROM hcp.jobs) <> 0 OR
     (SELECT count(*) FROM hcp.job_steps) <> 0 OR
     (SELECT count(*) FROM hcp.job_events) <> 0 OR
     (SELECT count(*) FROM hcp.resource_locks) <> 0 THEN
    RAISE EXCEPTION 'untrusted platform GUC must not bypass job RLS';
  END IF;
END $$;
RESET ROLE;
SQL

echo "TENANT RLS AND FAIL-CLOSED NEGATIVE TESTS: PASS"

# Uses only the disposable container and a restricted CI tenant role.
bash scripts/verify-job-enqueue.sh "$NAME"
bash scripts/verify-job-leases.sh "$NAME"

docker exec -i "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1 \
  < migrations/platform/000010_job_resource_leases.down.sql >/dev/null
docker exec -i "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1 \
  < migrations/platform/000009_tenant_ping_enqueue.down.sql >/dev/null
docker exec -i "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1 \
  < migrations/platform/000008_job_orchestrator_security.down.sql >/dev/null
removed="$(docker exec "$NAME" psql -U postgres -d hcp_test -Atc "
SELECT count(*) FROM information_schema.columns
WHERE table_schema='hcp' AND table_name='jobs' AND column_name='intent_fingerprint';")"
[[ "$removed" == "0" ]] || { echo "STOP: down migration did not remove fingerprint" >&2; exit 1; }
docker exec -i "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1 \
  < migrations/platform/000008_job_orchestrator_security.up.sql >/dev/null
docker exec -i "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1 \
  < migrations/platform/000009_tenant_ping_enqueue.up.sql >/dev/null
docker exec -i "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1 \
  < migrations/platform/000010_job_resource_leases.up.sql >/dev/null
restored="$(docker exec "$NAME" psql -U postgres -d hcp_test -Atc "
SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='hcp' AND c.relname IN ('jobs','job_steps','job_events','resource_locks')
  AND c.relrowsecurity AND c.relforcerowsecurity;")"
[[ "$restored" == "4" ]] || { echo "STOP: reapply RLS failure" >&2; exit 1; }
reapplied="$(docker exec "$NAME" psql -U postgres -d hcp_test -Atqc "
SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='hcp' AND p.proname='enqueue_tenant_ping';")"
[[ "$reapplied" == "1" ]] || { echo "STOP: enqueue function missing after reapply" >&2; exit 1; }
tokens="$(docker exec "$NAME" psql -U postgres -d hcp_test -Atqc "
SELECT count(*) FROM information_schema.columns
WHERE table_schema='hcp' AND table_name='resource_locks' AND column_name='fencing_token';")"
[[ "$tokens" == "1" ]] || { echo "STOP: fencing token not restored" >&2; exit 1; }
echo "UP/DOWN/REAPPLY: PASS"

python3 - "$OUT/job-orchestrator-receipt.json" "${GITHUB_SHA:-local}" "${GITHUB_RUN_ID:-local}" <<'PY'
import datetime, json, pathlib, sys
out, commit, run_id = sys.argv[1:]
receipt = {
  "schema_version": 1,
  "verification": "phase08-isolated-job-orchestrator-contract",
  "commit": commit,
  "run_id": run_id,
  "production_access": False,
  "provider_network_access": False,
  "execution_enabled": False,
  "checks": {
    "synthetic_read_only_intents": "PASS",
    "migrations_up": "PASS",
    "tenant_rls": "PASS",
    "children_rls": "PASS",
    "cross_tenant_write_rejected": "PASS",
    "missing_tenant_rejected": "PASS",
    "platform_guc_bypass_rejected": "PASS",
    "migration_down_reapply": "PASS",
    "tenant_atomic_enqueue": "PASS",
    "idempotency_conflict": "PASS",
    "concurrent_replay": "PASS",
    "fenced_lease_claim": "PASS",
    "lease_renew_release": "PASS",
    "lease_expiry_reconciliation": "PASS",
    "concurrent_claim_one_winner": "PASS"
  },
  "verified_at": datetime.datetime.now(datetime.timezone.utc).isoformat()
}
pathlib.Path(out).write_text(json.dumps(receipt,indent=2)+"\n", encoding="utf-8")
print(json.dumps(receipt,indent=2))
PY

echo "PHASE 08 ISOLATED JOB CONTRACT: PASS"
