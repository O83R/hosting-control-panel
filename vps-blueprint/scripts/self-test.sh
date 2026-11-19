#!/usr/bin/env bash
# Local static validation only; no host modification.
set -Eeuo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
echo '=== VPS BLUEPRINT SELF-TEST ==='
for file in bootstrap-vps.sh audit-source.sh verify-vps.sh deploy-monitoring.sh; do
  bash -n "$DIR/scripts/$file"
  echo "BASH_SYNTAX_PASS=$file"
done
bash "$DIR/scripts/bootstrap-vps.sh" --plan
echo 'BOOTSTRAP_PLAN=PASS'
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  NPM_IMAGE='jc21/nginx-proxy-manager:2.15.1' \
  KUMA_IMAGE='louislam/uptime-kuma:2.5.5' \
    docker compose -f "$DIR/monitoring/compose.yaml" config --quiet
  echo 'COMPOSE_PARSE=PASS'
else
  echo 'COMPOSE_PARSE=NOT_TESTED_DOCKER_COMPOSE_UNAVAILABLE'
fi
echo 'SELF_TEST=COMPLETE_NO_CHANGES'
