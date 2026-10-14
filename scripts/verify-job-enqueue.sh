#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Caller owns a disposable PostgreSQL container with Phase 08 migrations
# applied and the fixture tenants and hcp_jobs_reader role installed.
NAME="${1:?temporary postgres container is required}"
DB="hcp_test"
echo "=== ATOMIC SYNTHETIC ENQUEUE CONTRACT ==="

docker exec -i "$NAME" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 <<'SQL'
GRANT EXECUTE ON FUNCTION hcp.enqueue_tenant_ping(
  uuid, uuid, text, text, text, text
) TO hcp_jobs_reader;

SET ROLE hcp_jobs_reader;
SET hcp.scope = 'tenant';
SET hcp.tenant_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

DO $$
DECLARE
  v_id uuid;
  v_replayed boolean;
BEGIN
  SELECT result_job_id, was_replayed INTO v_id, v_replayed
  FROM hcp.enqueue_tenant_ping(
    '00000000-0000-0000-0000-000000000001',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'ci', 'repeat-key', 'node-1', repeat('a',64));
  IF v_id <> '00000000-0000-0000-0000-000000000001' OR v_replayed THEN
    RAISE EXCEPTION 'first enqueue must create one job';
  END IF;

  SELECT result_job_id, was_replayed INTO v_id, v_replayed
  FROM hcp.enqueue_tenant_ping(
    '00000000-0000-0000-0000-000000000002',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'ci', 'repeat-key', 'node-1', repeat('a',64));
  IF v_id <> '00000000-0000-0000-0000-000000000001' OR NOT v_replayed THEN
    RAISE EXCEPTION 'equal-key equal-intent must replay original job';
  END IF;

  BEGIN
    PERFORM * FROM hcp.enqueue_tenant_ping(
      '00000000-0000-0000-0000-000000000003',
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'ci', 'repeat-key', 'node-2', repeat('a',64));
    RAISE EXCEPTION 'different target accepted' USING ERRCODE = 'data_exception';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;

  BEGIN
    PERFORM * FROM hcp.enqueue_tenant_ping(
      '00000000-0000-0000-0000-000000000004',
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'ci', 'repeat-key', 'node-1', repeat('b',64));
    RAISE EXCEPTION 'different fingerprint accepted' USING ERRCODE = 'data_exception';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;

  BEGIN
    PERFORM * FROM hcp.enqueue_tenant_ping(
      '00000000-0000-0000-0000-000000000001',
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'ci', 'another-key', 'node-1', repeat('a',64));
    RAISE EXCEPTION 'same job ID with another key accepted' USING ERRCODE = 'data_exception';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;

  BEGIN
    PERFORM * FROM hcp.enqueue_tenant_ping(
      '00000000-0000-0000-0000-000000000005',
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'ci', 'bad-hash', 'node-1', 'not-a-sha256');
    RAISE EXCEPTION 'malformed fingerprint accepted' USING ERRCODE = 'data_exception';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;

  IF (SELECT count(*) FROM hcp.jobs WHERE idempotency_key = 'repeat-key') <> 1 THEN
    RAISE EXCEPTION 'idempotency created duplicate rows';
  END IF;
END $$;

-- Tenant B may independently reuse the same idempotency key.
SET hcp.tenant_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
DO $$
DECLARE
  v_id uuid;
  v_replayed boolean;
BEGIN
  SELECT result_job_id, was_replayed INTO v_id, v_replayed
  FROM hcp.enqueue_tenant_ping(
    '00000000-0000-0000-0000-000000000006',
    'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    'ci', 'repeat-key', 'node-2', repeat('c',64));
  IF v_id <> '00000000-0000-0000-0000-000000000006' OR v_replayed THEN
    RAISE EXCEPTION 'distinct tenant idempotency not isolated';
  END IF;
END $$;

-- A tenant may not claim another tenant's identity just by passing its ID.
DO $$
BEGIN
  BEGIN
    PERFORM * FROM hcp.enqueue_tenant_ping(
      '00000000-0000-0000-0000-000000000007',
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'ci', 'cross-tenant', 'node-1', repeat('a',64));
    RAISE EXCEPTION 'cross-tenant enqueue accepted' USING ERRCODE = 'data_exception';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;

SET hcp.scope = 'platform';
DO $$
BEGIN
  BEGIN
    PERFORM * FROM hcp.enqueue_tenant_ping(
      '00000000-0000-0000-0000-000000000008',
      'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
      'ci', 'platform-bypass', 'node-2', repeat('c',64));
    RAISE EXCEPTION 'platform GUC bypass accepted' USING ERRCODE = 'data_exception';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;

SET hcp.scope = 'tenant';
RESET hcp.tenant_id;
DO $$
BEGIN
  BEGIN
    PERFORM * FROM hcp.enqueue_tenant_ping(
      '00000000-0000-0000-0000-000000000009',
      'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
      'ci', 'no-context', 'node-2', repeat('c',64));
    RAISE EXCEPTION 'missing context accepted' USING ERRCODE = 'data_exception';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
SQL
echo "ENQUEUE REPLAY / CONFLICT / TENANT SCOPING: PASS"

# Two or more callers racing with the same key must create exactly one job.
# No host networking and no privileged role is used for the calls.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pids=()
for i in $(seq 11 18); do
  job_id="$(printf '00000000-0000-0000-0000-%012d' "$i")"
  (
    docker exec "$NAME" psql -U postgres -d "$DB" -AtqX -v ON_ERROR_STOP=1 \
      -c "SET ROLE hcp_jobs_reader; SET hcp.scope = 'tenant'; SET hcp.tenant_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; SELECT result_job_id::text || '|' || was_replayed::text FROM hcp.enqueue_tenant_ping('$job_id','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','ci','race-key','node-1',repeat('d',64));"
  ) > "$TMP/$i.out" 2>"$TMP/$i.err" &
  pids+=("$!")
done
for pid in "${pids[@]}"; do
  if ! wait "$pid"; then
    echo "STOP: racing enqueue request failed" >&2
    cat "$TMP"/*.err >&2
    exit 1
  fi
done
cat "$TMP"/*.out > "$TMP/results.txt"
[[ "$(wc -l < "$TMP/results.txt" | tr -d ' ')" == "8" ]] || {
  echo "STOP: expected 8 receipts" >&2; exit 1;
}
[[ "$(cut -d '|' -f 1 "$TMP/results.txt" | sort -u | wc -l | tr -d ' ')" == "1" ]] || {
  echo "STOP: racing enqueues produced different job IDs" >&2; exit 1;
}
[[ "$(grep -c '|f$' "$TMP/results.txt")" == "1" ]] || {
  echo "STOP: expected exactly one insert winner" >&2; exit 1;
}
[[ "$(grep -c '|t$' "$TMP/results.txt")" == "7" ]] || {
  echo "STOP: expected exactly seven idempotent replays" >&2; exit 1;
}
count="$(docker exec "$NAME" psql -U postgres -d "$DB" -Atqc "
SELECT count(*) FROM hcp.jobs
WHERE tenant_id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND idempotency_key='race-key';")"
[[ "$count" == "1" ]] || { echo "STOP: durable uniqueness race failed" >&2; exit 1; }
echo "CONCURRENT ENQUEUE (8 CALLERS, 1 INSERT, 7 REPLAYS): PASS"
