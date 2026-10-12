#!/usr/bin/env bash
set -Eeuo pipefail
D=(docker --context rootless)

echo "=== COMPOSE ==="
"${D[@]}" compose ps

echo
echo "=== HEALTH ==="
curl -fsS http://127.0.0.1:18100/healthz
echo

echo
echo "=== AUTH STATUS ==="
auth="$(curl -fsS http://127.0.0.1:18100/api/v1/auth/status)"
printf '%s\n' "$auth" | python3 -c '
import json,sys
a=json.load(sys.stdin)
print(a)
assert int(a["db_schema_version"])==2
assert int(a["user_count"])>=1
assert a["mode"]=="local"
assert a["password_kdf"]=="PBKDF2-HMAC-SHA256"
assert int(a["password_iterations"])>=600000
print("AUTH STATUS: PASS")
'

echo
echo "=== ACCESS GATE ==="
code="$(curl -sS -o /tmp/panel-v08-protected -w '%{http_code}' http://127.0.0.1:18100/api/v1/snapshot)"
echo "unauthenticated_snapshot_http=$code"
[ "$code" = "401" ] || { echo "STOP: protected API is not protected"; exit 1; }

code="$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:18100/)"
echo "unauthenticated_root_http=$code"
[ "$code" = "303" ] || { echo "STOP: root does not redirect to login"; exit 1; }

curl -fsS http://127.0.0.1:18100/login | grep -q 'تسجيل الدخول'
echo "LOGIN PAGE: PASS"

code="$(curl -sS -o /tmp/panel-v010-ping -w '%{http_code}' -X POST http://127.0.0.1:18100/api/v1/actions/ping)"
echo "unauthenticated_agent_ping_http=$code"
[ "$code" = "401" ] || { echo "STOP: action endpoint is not protected"; exit 1; }
echo "ACTION ACCESS GATE: PASS"

code="$(curl -sS -o /tmp/panel-v011-backup -w '%{http_code}' -X POST http://127.0.0.1:18100/api/v1/actions/backup-now)"
echo "unauthenticated_backup_now_http=$code"
[ "$code" = "401" ] || { echo "STOP: backup endpoint is not protected"; exit 1; }
echo "BACKUP ACCESS GATE: PASS"

code="$(curl -sS -o /tmp/panel-v012-history -w '%{http_code}' http://127.0.0.1:18100/api/v1/backups/history)"
echo "unauthenticated_backup_history_http=$code"
[ "$code" = "401" ] || { echo "STOP: backup history endpoint is not protected"; exit 1; }
echo "BACKUP HISTORY ACCESS GATE: PASS"

code="$(curl -sS -o /tmp/panel-v013-adapters -w '%{http_code}' http://127.0.0.1:18100/api/v1/backups/adapters)"
echo "unauthenticated_backup_adapters_http=$code"
[ "$code" = "401" ] || { echo "STOP: backup adapters endpoint is not protected"; exit 1; }
echo "BACKUP ADAPTERS ACCESS GATE: PASS"

code="$(curl -sS -o /tmp/panel-v014-preflight -w '%{http_code}' http://127.0.0.1:18100/api/v1/backups/preflight)"
echo "unauthenticated_backup_preflight_http=$code"
[ "$code" = "401" ] || { echo "STOP: backup preflight endpoint is not protected"; exit 1; }
echo "BACKUP PREFLIGHT ACCESS GATE: PASS"

code="$(curl -sS -o /tmp/panel-v015-contract -w '%{http_code}' http://127.0.0.1:18100/api/v1/backups/contract)"
echo "unauthenticated_backup_contract_http=$code"
[ "$code" = "401" ] || { echo "STOP: backup contract endpoint is not protected"; exit 1; }
echo "BACKUP CONTRACT ACCESS GATE: PASS"

code="$(curl -sS -o /tmp/panel-v016-project-backup -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' \
  -d '{"project_id":"ahkam"}' \
  http://127.0.0.1:18100/api/v1/actions/project-backup)"
echo "unauthenticated_project_backup_http=$code"
[ "$code" = "401" ] || { echo "STOP: project backup endpoint is not protected"; exit 1; }
echo "PROJECT BACKUP ACCESS GATE: PASS"

echo
echo "=== V0.20.1 UI SOURCE ==="
grep -q 'PROJECT BACKUP OPERATIONS' web/index.html
grep -q 'SAFE OPERATIONS' web/index.html
grep -q 'v0.20.1' web/index.html
grep -q 'confirm_project_id' main.go
grep -q 'data-project-backup-id' web/app.js
grep -q 'BACKUP_HISTORY_LIMIT=10' web/app.js
grep -q 'backup-ops-grid' web/app.js
grep -q 'tech-details' web/index.html
grep -q 'No production restore' web/index.html
echo "V0.20.1 UI SOURCE: PASS"

echo
echo "=== DATABASES ==="
"${D[@]}" compose exec -T panel sqlite3 -readonly /var/lib/panel/auth.sqlite \
  "SELECT 'users='||count(*) FROM users; SELECT 'sessions='||count(*) FROM sessions;"
"${D[@]}" compose exec -T panel sqlite3 -readonly /var/lib/panel/audit.sqlite \
  "SELECT 'audit_events='||count(*) FROM audit_events;"

echo
echo "=== MOUNTS ==="
mounts="$("${D[@]}" inspect hosting-control-panel-dev-panel-1 \
  --format '{{range .Mounts}}{{println .Type "|" .Name "|" .Source "->" .Destination "|" .RW}}{{end}}')"
echo "$mounts"
if printf '%s\n' "$mounts" | grep -E 'docker\.sock|/srv/apps/(alhafdat|ahkam|institute|water-factories)'; then
  echo "ERROR: forbidden production mount"; exit 1
fi
printf '%s\n' "$mounts" | grep -Fq '/srv/shared/hosting-panel-readonly -> /data | false' || exit 1
printf '%s\n' "$mounts" | grep -Fq 'hosting-control-panel-audit' || exit 1

echo
echo "VERIFY: PASS"
