#!/usr/bin/env bash
# Only on explicitly approved CLEAN new VPS, never the source.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FILE="$ROOT_DIR/monitoring/compose.yaml"
ENVFILE="$ROOT_DIR/monitoring/.env"
MODE=plan; ACK=no; EXPECTED=
while (($#)); do
  case "$1" in
    --plan) MODE=plan; shift ;;
    --apply) MODE=apply; shift ;;
    --expected-hostname) EXPECTED="$2"; shift 2 ;;
    --ack-new-vps) ACK=yes; shift ;;
    *) echo "BAD_ARG=$1"; exit 2 ;;
  esac
done
HOST="$(hostname -s)"
echo "MODE=$MODE HOST=$HOST TARGET=monitoring_only"
echo "NO_SECRETS_OR_DATA_TRANSFER=YES"
if [[ ! -f "$ENVFILE" ]]; then
  echo 'INCOMPLETE=copy monitoring/.env.example to monitoring/.env and select reviewed images'
  exit 1
fi
if grep -qE 'REPLACE_WITH|CHANGE_ME|^NPM_IMAGE=$|^KUMA_IMAGE=$' "$ENVFILE"; then
  echo 'BLOCKED=UNREVIEWED_IMAGE_TAGS'; exit 1
fi
command -v docker >/dev/null || { echo 'BLOCKED=DOCKER_NOT_INSTALLED'; exit 1; }
docker compose --env-file "$ENVFILE" -f "$FILE" config --quiet
echo 'COMPOSE_VALIDATION=PASS'
if [[ "$MODE" == plan ]]; then
  echo 'PLAN_ONLY=YES'
  echo 'Public ports: 80/443; localhost-only admin: 81/3001'
  echo 'New empty storage under /srv/vps-shared; no domains or credentials imported'
  exit 0
fi
[[ "$EUID" == 0 && "$ACK" == yes ]] || { echo 'BLOCKED=ROOT_ACK_REQUIRED'; exit 3; }
[[ -n "$EXPECTED" && "$EXPECTED" == "$HOST" && "$HOST" != apps-prod-01 ]] || {
  echo 'BLOCKED=HOSTNAME_MISMATCH_OR_SOURCE'; exit 3;
}
. /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_ID" == 24.04 ]] || { echo 'BLOCKED=UBUNTU_24_04_REQUIRED'; exit 3; }
if docker ps -a --format '{{.Names}}' | grep -Ex 'nginx-proxy-manager|uptime-kuma' >/dev/null; then
  echo 'BLOCKED=MONITOR_ALREADY_EXISTS'; exit 3
fi
install -d -m 0750 /srv/vps-shared/npm/data \
  /srv/vps-shared/npm/letsencrypt /srv/vps-shared/kuma/data
docker compose --env-file "$ENVFILE" -f "$FILE" up -d
docker compose --env-file "$ENVFILE" -f "$FILE" ps
echo 'MONITORING_DEPLOYED=VERIFY_HEALTH_AND_ADMIN_LOCALHOST_BEFORE_ACCEPTING'
