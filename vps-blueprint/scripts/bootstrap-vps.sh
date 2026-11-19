#!/usr/bin/env bash
# New VPS ONLY. Refuses known source, existing containers and unapproved apply.
set -Eeuo pipefail
MODE=plan; PHASE=all; EXPECTED=; ACK=no; USERS=
while (($#)); do
  case "$1" in
    --plan) MODE=plan; shift ;;
    --apply) MODE=apply; shift ;;
    --phase) PHASE="$2"; shift 2 ;;
    --users) USERS="$2"; shift 2 ;;
    --expected-hostname) EXPECTED="$2"; shift 2 ;;
    --ack-new-vps) ACK=yes; shift ;;
    -h|--help) echo 'Usage: [--plan] | --apply --phase base|docker|users|all --expected-hostname NAME --ack-new-vps [--users sitea,siteb]'; exit 0 ;;
    *) echo "BAD_ARG=$1"; exit 2 ;;
  esac
done
case "$PHASE" in base|docker|users|all) ;; *) echo "BAD_PHASE=$PHASE"; exit 2;; esac
. /etc/os-release
HOST="$(hostname -s)"
echo "MODE=$MODE HOST=$HOST OS=$ID:$VERSION_ID PHASE=$PHASE"
echo "SSH_FIREWALL_CHANGES=NONE; REBOOT=NONE; DATA_COPIED=NONE"
if [[ "$MODE" == plan ]]; then
  echo 'base: apt prerequisites, unattended no-auto-reboot, /srv dirs'
  echo 'docker: official Docker apt repo, Engine, Compose, rootless extras'
  echo "users: explicit rootless accounts only: $USERS"
  echo 'monitoring: separate script, not installed here'
  exit 0
fi
[[ "$EUID" == 0 && "$ACK" == yes ]] || { echo 'BLOCKED=ROOT_AND_ACK_REQUIRED'; exit 3; }
[[ -n "$EXPECTED" && "$EXPECTED" == "$HOST" && "$HOST" != apps-prod-01 ]] || { echo 'BLOCKED=WRONG_HOST'; exit 3; }
[[ "$ID" == ubuntu && "$VERSION_ID" == 24.04 ]] || { echo 'BLOCKED=REQUIRE_UBUNTU_24_04'; exit 3; }
[[ "$(stat -fc %T /sys/fs/cgroup)" == cgroup2fs ]] || { echo 'BLOCKED=CGROUP_V2'; exit 3; }
if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker.service; then
  docker info >/dev/null || { echo 'BLOCKED=DOCKER_API'; exit 3; }
  [[ -z "$(docker ps -aq)" ]] || { echo 'BLOCKED=CONTAINERS_EXIST'; exit 3; }
fi
base() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl gnupg jq git htop vim unzip ufw \
    unattended-upgrades uidmap dbus-user-session slirp4netns fuse-overlayfs
  printf 'Unattended-Upgrade::Automatic-Reboot "false";\n' \
    > /etc/apt/apt.conf.d/90-vps-blueprint-no-auto-reboot
  install -d -m 0755 /srv/apps /srv/vps-shared
  install -d -m 0750 /srv/backups
  echo 'BASE=PASS'
}
docker_install() {
  for pkg in docker.io docker-doc podman-docker docker-compose docker-compose-v2; do
    if dpkg -s "$pkg" 2>/dev/null | grep -q '^Status: install ok installed'; then
      echo "BLOCKED=CONFLICT_PACKAGE:$pkg"; return 1
    fi
  done
  export DEBIAN_FRONTEND=noninteractive
  install -d -m 0755 /etc/apt/keyrings
  if [[ ! -s /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      -o /etc/apt/keyrings/docker.asc
  fi
  chmod a+r /etc/apt/keyrings/docker.asc
  printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: /etc/apt/keyrings/docker.asc\n' \
    "$VERSION_CODENAME" "$(dpkg --print-architecture)" \
    > /etc/apt/sources.list.d/docker.sources
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras
  systemctl enable --now docker.service
  docker compose version
  echo 'DOCKER=PASS'
}
rootless_users() {
  [[ -n "$USERS" ]] || { echo 'BLOCKED=USERS_REQUIRED'; return 1; }
  command -v dockerd-rootless-setuptool.sh >/dev/null || { echo 'BLOCKED=ROOTLESS_EXTRAS'; return 1; }
  local name uid
  for name in $(tr ',' ' ' <<< "$USERS"); do
    [[ "$name" =~ ^[a-z_][a-z0-9_-]{2,30}$ && "$name" != root ]] || {
      echo "BLOCKED=INVALID_USER:$name"; return 1;
    }
  done
  for name in $(tr ',' ' ' <<< "$USERS"); do
    if ! id "$name" >/dev/null 2>&1; then
      useradd -m -U -s /bin/bash "$name"
      passwd -l "$name" >/dev/null || true
    fi
    uid="$(id -u "$name")"
    grep -q "^$name:" /etc/subuid && grep -q "^$name:" /etc/subgid || {
      echo "BLOCKED=SUBID_MISSING:$name"; return 1;
    }
    loginctl enable-linger "$name"
    systemctl start "user@$uid.service"
    if [[ ! -f "/home/$name/.config/systemd/user/docker.service" ]]; then
      runuser -u "$name" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
        dockerd-rootless-setuptool.sh install
    fi
    runuser -u "$name" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
      systemctl --user enable --now docker.service
    runuser -u "$name" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
      DOCKER_HOST="unix:///run/user/$uid/docker.sock" \
      docker info --format 'ROOTLESS={{.ServerVersion}} CGROUP={{.CgroupVersion}}'
    echo "ROOTLESS_USER_READY=$name"
  done
}
case "$PHASE" in
  base) base ;;
  docker) docker_install ;;
  users) rootless_users ;;
  all) base; docker_install; if [[ -n "$USERS" ]]; then rootless_users; fi ;;
esac
echo 'BOOTSTRAP_FINISHED=PASS'
