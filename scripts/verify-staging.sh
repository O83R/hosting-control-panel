#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

IMAGE="hosting-control-panel-verifier:${GITHUB_SHA:-local}"
NAME="hcp-verifier-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
PORT="${HCP_STAGING_PORT:-18200}"
WORK="$ROOT/.ci-staging"
OUT="$ROOT/.ci-out"
SNAPSHOT="$WORK/host-snapshot.json"
AUDIT_VOL="${NAME}-audit"
ACTIONS_VOL="${NAME}-actions"

cleanup() {
  set +e
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker volume rm "$AUDIT_VOL" "$ACTIONS_VOL" >/dev/null 2>&1 || true
  docker image rm "$IMAGE" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT"

cat >"$SNAPSHOT" <<'JSON'
{
  "schema_version": 5,
  "generated_at": "2026-01-01T00:00:00Z",
  "metadata": {
    "contract_name": "hosting-panel-snapshot",
    "contract_version": "5.0",
    "collector_version": "ci-synthetic"
  },
  "projects": []
}
JSON
chmod 0644 "$SNAPSHOT"

echo "=== INDEPENDENT VERIFIER ==="
echo "image=$IMAGE"
echo "container=$NAME"
echo "loopback_port=$PORT"

echo
echo "=== CLEAN DOCKER BUILD ==="
docker build --pull=false --tag "$IMAGE" .
echo "DOCKER BUILD: PASS"

docker volume create "$AUDIT_VOL" >/dev/null
docker volume create "$ACTIONS_VOL" >/dev/null

# Named Docker volumes are root-owned when first created. The production image
# runs as uid 10001, so initialize only these ephemeral CI volumes explicitly.
for vol in "$AUDIT_VOL" "$ACTIONS_VOL"; do
  docker run --rm --user 0 --entrypoint /bin/sh \
    -v "$vol:/target" "$IMAGE" \
    -c 'chown -R 10001:10001 /target && chmod 0750 /target'
done
echo "EPHEMERAL VOLUME OWNERSHIP: PASS"

echo
echo "=== EPHEMERAL LOOPBACK STAGING ==="
docker run -d \
  --name "$NAME" \
  --read-only \
  --tmpfs /tmp:size=16m,mode=1777 \
  --security-opt no-new-privileges:true \
  --cap-drop ALL \
  --pids-limit 128 \
  --memory 256m \
  --cpus 0.50 \
  -e HOST_SNAPSHOT=/data/host-snapshot.json \
  -e AUDIT_DB=/var/lib/panel/audit.sqlite \
  -e AUTH_DB=/var/lib/panel/auth.sqlite \
  -e ACTIONS_ROOT=/var/lib/actions \
  -e PANEL_COOKIE_SECURE=false \
  -p "127.0.0.1:${PORT}:8080" \
  -v "$SNAPSHOT:/data/host-snapshot.json:ro" \
  -v "$AUDIT_VOL:/var/lib/panel" \
  -v "$ACTIONS_VOL:/var/lib/actions" \
  "$IMAGE" >/dev/null

ready=false
for _ in $(seq 1 45); do
  if curl -fsS "http://127.0.0.1:${PORT}/healthz" >"$WORK/health.json" 2>/dev/null; then
    ready=true
    break
  fi
  sleep 1
done
if [[ "$ready" != "true" ]]; then
  docker logs "$NAME" || true
  echo "STOP: staging health endpoint did not become ready" >&2
  exit 1
fi

python3 - "$WORK/health.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1],encoding="utf-8"))
assert x.get("status")=="ok", x
assert x.get("snapshot") is True, x
assert x.get("audit") is True, x
assert x.get("auth") is True, x
assert x.get("schema_version")==5, x
print("HEALTH CONTRACT: PASS")
PY

curl -fsS "http://127.0.0.1:${PORT}/api/v1/auth/status" >"$WORK/auth.json"
python3 - "$WORK/auth.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1],encoding="utf-8"))
assert int(x.get("db_schema_version",0))==2, x
assert int(x.get("user_count",-1))==0, x
assert x.get("mode")=="local", x
print("AUTH BOOTSTRAP CONTRACT: PASS")
PY

code="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/api/v1/snapshot")"
[[ "$code" == "401" ]] || { echo "STOP: snapshot endpoint expected 401, got $code" >&2; exit 1; }
echo "UNAUTHENTICATED API GATE: PASS"

code="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/")"
[[ "$code" == "303" ]] || { echo "STOP: root expected 303, got $code" >&2; exit 1; }
echo "LOGIN REDIRECT GATE: PASS"

curl -fsS "http://127.0.0.1:${PORT}/login" | grep -Fq 'تسجيل الدخول'
echo "LOGIN PAGE: PASS"

echo
echo "=== RUNTIME ISOLATION ==="
docker inspect "$NAME" >"$WORK/inspect.json"
python3 - "$WORK/inspect.json" "$PORT" <<'PY'
import json,sys
x=json.load(open(sys.argv[1],encoding="utf-8"))[0]
port=sys.argv[2]
hc=x["HostConfig"]
assert hc.get("ReadonlyRootfs") is True, hc
assert "ALL" in (hc.get("CapDrop") or []), hc.get("CapDrop")
assert any(v.startswith("no-new-privileges") for v in (hc.get("SecurityOpt") or [])), hc.get("SecurityOpt")
ports=x["NetworkSettings"]["Ports"]["8080/tcp"]
assert ports and ports[0]["HostIp"]=="127.0.0.1", ports
assert ports[0]["HostPort"]==port, ports
allowed={"/data/host-snapshot.json","/var/lib/panel","/var/lib/actions"}
for m in x.get("Mounts",[]):
    assert m.get("Destination") in allowed, m
    src=(m.get("Source") or "").lower()
    assert "docker.sock" not in src, m
    assert "/srv/apps/" not in src, m
print("RUNTIME ISOLATION: PASS")
PY

image_id="$(docker image inspect "$IMAGE" --format '{{.Id}}')"
commit="${GITHUB_SHA:-local}"
run_id="${GITHUB_RUN_ID:-local}"

python3 - "$OUT/verifier-receipt.json" "$commit" "$run_id" "$image_id" "$PORT" <<'PY'
import datetime,json,pathlib,sys
out,commit,run_id,image_id,port=sys.argv[1:]
payload={
  "schema_version":1,
  "verifier":"github-actions-independent-staging",
  "commit":commit,
  "run_id":run_id,
  "image_id":image_id,
  "staging_bind":"127.0.0.1:"+port,
  "production_access":False,
  "production_database_access":False,
  "production_restore_enabled":False,
  "checks":{
    "clean_docker_build":"PASS",
    "health_contract":"PASS",
    "auth_bootstrap_contract":"PASS",
    "unauthenticated_api_gate":"PASS",
    "login_redirect_gate":"PASS",
    "runtime_isolation":"PASS"
  },
  "verified_at":datetime.datetime.now(datetime.timezone.utc).isoformat()
}
pathlib.Path(out).write_text(json.dumps(payload,indent=2)+"\n",encoding="utf-8")
print(json.dumps(payload,indent=2))
PY

echo
echo "INDEPENDENT VERIFIER: PASS"
echo "receipt=$OUT/verifier-receipt.json"
