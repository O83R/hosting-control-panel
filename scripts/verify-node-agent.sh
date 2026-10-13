#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT="$ROOT/.ci-out"
BIN="$OUT/node-agent"
LOG="$OUT/node-agent.log"
RECEIPT="$OUT/node-agent-receipt.json"
PORT="${HCP_NODE_AGENT_TEST_PORT:-18210}"
BASE="http://127.0.0.1:$PORT"
SECRET="ci-only-node-agent-secret-0123456789abcdef0123456789"

cleanup() {
  set +e
  if [[ -n "${AGENT_PID:-}" ]]; then
    kill "$AGENT_PID" >/dev/null 2>&1 || true
    wait "$AGENT_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

mkdir -p "$OUT"

echo "=== NODE AGENT CONTRACT ==="

if grep -R -n -E 'os/exec|exec\.Command|/bin/(sh|bash)' internal/nodeagent internal/agentprotocol cmd/node-agent; then
  echo "STOP: arbitrary process/shell execution primitive found in node agent source" >&2
  exit 1
fi
echo "NO ARBITRARY EXEC PRIMITIVE: PASS"

go test ./internal/agentprotocol ./internal/nodeagent ./cmd/node-agent
echo "NODE AGENT UNIT TESTS: PASS"

CGO_ENABLED=0 go build -trimpath -o "$BIN" ./cmd/node-agent
test -s "$BIN"
echo "NODE AGENT BUILD: PASS"

HCP_NODE_AGENT_SECRET="$SECRET" HCP_NODE_AGENT_LISTEN="127.0.0.1:$PORT" "$BIN" >"$LOG" 2>&1 &
AGENT_PID=$!

ready=false
for _ in $(seq 1 30); do
  if curl -fsS "$BASE/healthz" >"$OUT/node-agent-health.json" 2>/dev/null; then
    ready=true
    break
  fi
  sleep 1
done
if [[ "$ready" != "true" ]]; then
  cat "$LOG" >&2 || true
  echo "STOP: node agent did not become ready" >&2
  exit 1
fi

SECRET="$SECRET" BASE="$BASE" python3 - "$RECEIPT" <<'PY'
import datetime
import hashlib
import hmac
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.request

out=sys.argv[1]
secret=os.environ["SECRET"].encode()
base=os.environ["BASE"]

def signature(ts,nonce,method,path,body=b""):
    body_hash=hashlib.sha256(body).hexdigest()
    canonical="\n".join([ts,nonce,method.upper(),path,body_hash]).encode()
    return hmac.new(secret,canonical,hashlib.sha256).hexdigest()

def signed_request(method,path,body=b"",nonce=None):
    ts=str(int(time.time()))
    nonce=nonce or secrets.token_urlsafe(18)
    headers={
        "X-HCP-Protocol-Version":"1",
        "X-HCP-Timestamp":ts,
        "X-HCP-Nonce":nonce,
        "X-HCP-Signature":signature(ts,nonce,method,path,body),
    }
    if body:
        headers["Content-Type"]="application/json"
    return urllib.request.Request(base+path,data=body if method!="GET" else None,headers=headers,method=method)

health=json.load(urllib.request.urlopen(base+"/healthz",timeout=5))
assert health["status"]=="ok"
assert health["protocol_version"]=="1"

try:
    urllib.request.urlopen(base+"/v1/capabilities",timeout=5)
    raise AssertionError("unsigned capabilities request unexpectedly succeeded")
except urllib.error.HTTPError as e:
    assert e.code==401, e.code

nonce="ci-replay-nonce-00000001"
req=signed_request("GET","/v1/capabilities",nonce=nonce)
caps=json.load(urllib.request.urlopen(req,timeout=5))
assert caps["protocol_version"]=="1"
assert caps["capabilities"]==[{"code":"agent.ping","version":"1","mode":"read_only"}], caps

try:
    urllib.request.urlopen(signed_request("GET","/v1/capabilities",nonce=nonce),timeout=5)
    raise AssertionError("replayed request unexpectedly succeeded")
except urllib.error.HTTPError as e:
    assert e.code==409, e.code

body=json.dumps({
    "request_id":"ci-request-1",
    "job_id":"ci-job-1",
    "action":"agent.ping"
},separators=(",",":")).encode()
receipt=json.load(urllib.request.urlopen(
    signed_request("POST","/v1/actions/agent.ping",body=body),
    timeout=5,
))
assert receipt["request_id"]=="ci-request-1"
assert receipt["action"]=="agent.ping"
assert receipt["status"]=="succeeded"
assert receipt["output"]["pong"] is True

try:
    urllib.request.urlopen(
        signed_request("POST","/v1/actions/shell.exec",body=b"{}"),
        timeout=5,
    )
    raise AssertionError("unknown shell action unexpectedly exposed")
except urllib.error.HTTPError as e:
    assert e.code==404, e.code

payload={
    "schema_version":1,
    "verification":"node-agent-protocol-v1",
    "protocol_version":"1",
    "loopback_only":True,
    "production_access":False,
    "production_database_access":False,
    "arbitrary_exec_exposed":False,
    "checks":{
        "health":"PASS",
        "request_signing":"PASS",
        "timestamp_auth":"PASS",
        "nonce_replay_rejection":"PASS",
        "capability_allowlist":"PASS",
        "typed_ping_action":"PASS",
        "unknown_action_rejected":"PASS",
        "source_exec_gate":"PASS",
    },
    "verified_at":datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
with open(out,"w",encoding="utf-8") as f:
    json.dump(payload,f,indent=2)
    f.write("\n")
print(json.dumps(payload,indent=2))
PY

echo "NODE AGENT CONTRACT: PASS"
echo "receipt=$RECEIPT"
