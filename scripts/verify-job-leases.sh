#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

NAME="${1:?isolated PostgreSQL container name required}"
echo "=== PHASE 08 FENCED RESOURCE LEASE CONTRACT ==="

# Permissions exist exclusively in ephemeral CI PostgreSQL. All functions are
# SECURITY INVOKER and remain ungranted in the deployment migrations.
docker exec -i "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1 <<'SQL'
GRANT UPDATE ON hcp.jobs TO hcp_jobs_reader;
GRANT SELECT,INSERT,UPDATE ON hcp.resource_locks TO hcp_jobs_reader;
GRANT EXECUTE ON FUNCTION hcp.claim_tenant_ping_lease(uuid,integer) TO hcp_jobs_reader;
GRANT EXECUTE ON FUNCTION hcp.renew_tenant_ping_lease(uuid,bigint,integer) TO hcp_jobs_reader;
GRANT EXECUTE ON FUNCTION hcp.release_tenant_ping_lease(uuid,bigint) TO hcp_jobs_reader;
GRANT EXECUTE ON FUNCTION hcp.reconcile_expired_tenant_ping_lease(uuid,bigint) TO hcp_jobs_reader;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='hcp' AND table_name='resource_locks'
      AND column_name='fencing_token'
  ) THEN
    RAISE EXCEPTION 'missing fencing token';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname='resource_locks_job_id_fkey' AND confdeltype='r'
  ) THEN
    RAISE EXCEPTION 'lease history must survive job deletion';
  END IF;
END $$;

SET ROLE hcp_jobs_reader;
SET hcp.scope='tenant';
SET hcp.tenant_id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

SELECT * FROM hcp.enqueue_tenant_ping(
  '10000000-0000-0000-0000-000000000001',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'ci','lease-job-a','node-lease',repeat('a',64));
SELECT * FROM hcp.enqueue_tenant_ping(
  '10000000-0000-0000-0000-000000000002',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'ci','lease-job-b','node-lease',repeat('b',64));
SELECT * FROM hcp.enqueue_tenant_ping(
  '10000000-0000-0000-0000-000000000003',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'ci','lease-job-c','node-lease',repeat('c',64));

DO $$
DECLARE
  v_claimed boolean;
  v_fence bigint;
  v_exp timestamptz;
BEGIN
  SELECT claimed,token,lease_until INTO v_claimed,v_fence,v_exp
  FROM hcp.claim_tenant_ping_lease(
    '10000000-0000-0000-0000-000000000001',30);
  IF v_claimed IS DISTINCT FROM true OR v_fence <> 1 OR v_exp <= now() THEN
    RAISE EXCEPTION 'initial lease claim failed';
  END IF;

  SELECT claimed,token INTO v_claimed,v_fence
  FROM hcp.claim_tenant_ping_lease(
    '10000000-0000-0000-0000-000000000002',30);
  IF v_claimed IS DISTINCT FROM false OR v_fence IS NOT NULL THEN
    RAISE EXCEPTION 'contending job acquired active lease';
  END IF;

  IF hcp.renew_tenant_ping_lease(
    '10000000-0000-0000-0000-000000000001',999,30) THEN
    RAISE EXCEPTION 'wrong fence token renewed active lease';
  END IF;
  IF NOT hcp.renew_tenant_ping_lease(
    '10000000-0000-0000-0000-000000000001',1,30) THEN
    RAISE EXCEPTION 'owner renewal rejected';
  END IF;
  IF hcp.release_tenant_ping_lease(
    '10000000-0000-0000-0000-000000000001',1) THEN
    RAISE EXCEPTION 'running job released lease before terminal state';
  END IF;
  BEGIN
    PERFORM * FROM hcp.claim_tenant_ping_lease(
      '10000000-0000-0000-0000-000000000002',301);
    RAISE EXCEPTION 'unbounded lease TTL accepted'
      USING ERRCODE='data_exception';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
END $$;
RESET ROLE;

-- Controlled clock simulation (no sleeps and no external clock mutation):
-- expire one synthetic lock while satisfying its acquired_at constraint.
UPDATE hcp.resource_locks
SET acquired_at=now()-interval '2 hours',
    expires_at=now()-interval '1 hour'
WHERE resource_type='node' AND resource_id='node-lease';

SET ROLE hcp_jobs_reader;
SET hcp.scope='tenant';
SET hcp.tenant_id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

DO $$
DECLARE
  v_claimed boolean;
  v_fence bigint;
BEGIN
  SELECT claimed,token INTO v_claimed,v_fence
  FROM hcp.claim_tenant_ping_lease(
    '10000000-0000-0000-0000-000000000002',30);
  IF v_claimed IS DISTINCT FROM true OR v_fence<>2 THEN
    RAISE EXCEPTION 'expired lease takeover must increment fence';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM hcp.jobs
    WHERE id='10000000-0000-0000-0000-000000000001'
      AND status='failed' AND error_code='LEASE_EXPIRED'
  ) THEN
    RAISE EXCEPTION 'previous crashed owner not reconciled';
  END IF;
  IF hcp.renew_tenant_ping_lease(
    '10000000-0000-0000-0000-000000000001',1,30) THEN
    RAISE EXCEPTION 'stale owner renewed after takeover';
  END IF;
  IF hcp.release_tenant_ping_lease(
    '10000000-0000-0000-0000-000000000001',1) THEN
    RAISE EXCEPTION 'stale owner released newer owner lock';
  END IF;
  IF hcp.reconcile_expired_tenant_ping_lease(
    '10000000-0000-0000-0000-000000000001',1) THEN
    RAISE EXCEPTION 'stale reconcile touched transferred lease';
  END IF;

  -- No real agent calls: synthetic verification is represented by test status.
  UPDATE hcp.jobs SET status='succeeded'
   WHERE id='10000000-0000-0000-0000-000000000002';
  IF NOT hcp.release_tenant_ping_lease(
    '10000000-0000-0000-0000-000000000002',2) THEN
    RAISE EXCEPTION 'verified terminal release failed';
  END IF;
  IF hcp.release_tenant_ping_lease(
    '10000000-0000-0000-0000-000000000002',2) THEN
    RAISE EXCEPTION 'duplicate release accepted';
  END IF;

  SELECT claimed,token INTO v_claimed,v_fence
  FROM hcp.claim_tenant_ping_lease(
    '10000000-0000-0000-0000-000000000003',30);
  IF v_claimed IS DISTINCT FROM true OR v_fence<>3 THEN
    RAISE EXCEPTION 'release then reclaim must advance fence';
  END IF;
END $$;

SELECT * FROM hcp.enqueue_tenant_ping(
  '10000000-0000-0000-0000-000000000004',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'ci','reconcile-job','node-reconcile',repeat('d',64));
DO $$
DECLARE
  v_claimed boolean;
  v_fence bigint;
BEGIN
  SELECT claimed,token INTO v_claimed,v_fence
  FROM hcp.claim_tenant_ping_lease(
    '10000000-0000-0000-0000-000000000004',30);
  IF v_claimed IS DISTINCT FROM true OR v_fence<>1 THEN
    RAISE EXCEPTION 'isolated reconcile fixture claim failed';
  END IF;
END $$;
RESET ROLE;

UPDATE hcp.resource_locks
SET acquired_at=now()-interval '2 hours',
    expires_at=now()-interval '1 hour'
WHERE resource_type='node' AND resource_id='node-reconcile';

SET ROLE hcp_jobs_reader;
SET hcp.scope='tenant';
SET hcp.tenant_id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
DO $$
BEGIN
  IF NOT hcp.reconcile_expired_tenant_ping_lease(
    '10000000-0000-0000-0000-000000000004',1) THEN
    RAISE EXCEPTION 'expired crashed lease not reconciled';
  END IF;
  IF hcp.reconcile_expired_tenant_ping_lease(
    '10000000-0000-0000-0000-000000000004',1) THEN
    RAISE EXCEPTION 'duplicate reconcile modified terminal job';
  END IF;
  IF hcp.renew_tenant_ping_lease(
    '10000000-0000-0000-0000-000000000004',1,30) THEN
    RAISE EXCEPTION 'reconciled failed job renewed lease';
  END IF;
END $$;
RESET ROLE;

-- A cross-tenant caller must not acquire another tenant's resource even
-- after expiry, and must not be able to renew the first tenant's token.
SET ROLE hcp_jobs_reader;
SET hcp.scope='tenant';
SET hcp.tenant_id='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
SELECT * FROM hcp.enqueue_tenant_ping(
  '20000000-0000-0000-0000-000000000001',
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  'ci','tenant-b-lease','node-b',repeat('e',64));
SELECT * FROM hcp.enqueue_tenant_ping(
  '20000000-0000-0000-0000-000000000002',
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  'ci','tenant-b-conflict','node-reconcile',repeat('f',64));
DO $$
DECLARE
  v_claimed boolean;
  v_fence bigint;
BEGIN
  SELECT claimed,token INTO v_claimed,v_fence
  FROM hcp.claim_tenant_ping_lease(
    '20000000-0000-0000-0000-000000000001',30);
  IF v_claimed IS DISTINCT FROM true OR v_fence <> 1 THEN
    RAISE EXCEPTION 'tenant-b independently scoped lease failed';
  END IF;

  IF hcp.renew_tenant_ping_lease(
    '10000000-0000-0000-0000-000000000003',3,30) THEN
    RAISE EXCEPTION 'cross-tenant renewal permitted';
  END IF;

  BEGIN
    PERFORM * FROM hcp.claim_tenant_ping_lease(
      '20000000-0000-0000-0000-000000000002',30);
    RAISE EXCEPTION 'cross-tenant resource takeover accepted'
      USING ERRCODE='data_exception';
  EXCEPTION WHEN insufficient_privilege OR check_violation OR unique_violation THEN
    NULL;
  END;
END $$;
RESET ROLE;
SQL
echo "LEASE FENCING / RENEW / RELEASE / RECOVERY / TENANT ISOLATION: PASS"

# Two jobs on one node, two independent DB sessions, one winner. The verifier
# exercises metadata claims only (no real actions or remote access).
docker exec -i "$NAME" psql -U postgres -d hcp_test -v ON_ERROR_STOP=1 <<'SQL'
SET ROLE hcp_jobs_reader;
SET hcp.scope='tenant';
SET hcp.tenant_id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
SELECT * FROM hcp.enqueue_tenant_ping(
  '30000000-0000-0000-0000-000000000001',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'ci','race-claim-a','node-race-claim',repeat('1',64));
SELECT * FROM hcp.enqueue_tenant_ping(
  '30000000-0000-0000-0000-000000000002',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'ci','race-claim-b','node-race-claim',repeat('2',64));
RESET ROLE;
SQL

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
pids=()
for i in 1 2; do
  job_id="$(printf '30000000-0000-0000-0000-%012d' "$i")"
  (
    docker exec "$NAME" psql -U postgres -d hcp_test -AtqX -v ON_ERROR_STOP=1 \
      -c "SET ROLE hcp_jobs_reader; SET hcp.scope='tenant'; SET hcp.tenant_id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; SELECT claimed::text || '|' || coalesce(token::text,'none') FROM hcp.claim_tenant_ping_lease('$job_id',30);"
  ) >"$TEMP_DIR/$i.out" 2>"$TEMP_DIR/$i.err" &
  pids+=("$!")
done
for pid in "${pids[@]}"; do
  if ! wait "$pid"; then
    echo "STOP: concurrent lease request failed" >&2
    cat "$TEMP_DIR"/*.err >&2
    exit 1
  fi
done

cat "$TEMP_DIR"/*.out > "$TEMP_DIR/results.txt"
[[ "$(wc -l < "$TEMP_DIR/results.txt" | tr -d ' ')" == "2" ]] || {
  echo "STOP: expected 2 claim receipts" >&2; exit 1;
}
[[ "$(grep -c '^true|1$' "$TEMP_DIR/results.txt" || true)" == "1" ]] || {
  echo "STOP: expected exactly one claim winner" >&2; exit 1;
}
[[ "$(grep -c '^false|none$' "$TEMP_DIR/results.txt" || true)" == "1" ]] || {
  echo "STOP: expected one rejected contending worker" >&2; exit 1;
}
running="$(docker exec "$NAME" psql -U postgres -d hcp_test -Atqc "
SELECT count(*) FROM hcp.jobs
WHERE id::text LIKE '30000000-0000-0000-0000-%' AND status='running';")"
[[ "$running" == "1" ]] || { echo "STOP: more than one job running" >&2; exit 1; }
echo "CONCURRENT LEASE CLAIM: 1 WINNER / 1 DENIED — PASS"
