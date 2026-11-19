#!/usr/bin/env bash
# Read only. No changes or connectivity to production resources.
set -uo pipefail
PASS=0; INCOMPLETE=0
ok(){ echo "PASS=$1"; PASS=$((PASS+1)); }
pending(){ echo "INCOMPLETE=$1"; INCOMPLETE=$((INCOMPLETE+1)); }
echo '=== NEW VPS ACCEPTANCE ==='
echo 'MODE=READ_ONLY'
. /etc/os-release
if [[ "$ID" == ubuntu && "$VERSION_ID" == 24.04 ]]; then ok ubuntu_24_04; else pending os_version; fi
if [[ "$(stat -fc %T /sys/fs/cgroup)" == cgroup2fs ]]; then ok cgroup_v2; else pending cgroup; fi
if command -v docker >/dev/null 2>&1; then
  docker --version
  docker compose version 2>/dev/null && ok docker_compose || pending docker_compose
else pending docker_not_installed; fi
if systemctl is-active --quiet docker.service; then ok docker_daemon; else pending docker_daemon; fi
if systemctl is-active --quiet unattended-upgrades.service; then ok updates_active; else pending updates_not_active; fi
if grep -q 'Automatic-Reboot "false"' /etc/apt/apt.conf.d/90-vps-blueprint-no-auto-reboot 2>/dev/null; then
  ok unattended_no_auto_reboot
else pending auto_reboot_policy; fi
if [[ -d /srv/apps && -d /srv/backups ]]; then ok srv_structure; else pending srv_structure; fi
echo '=== ROOTLESS USER SERVICES (OPTIONAL) ==='
for user in "$@"; do
  uid="$(id -u "$user" 2>/dev/null)" || { pending "unknown_user_$user"; continue; }
  if sudo -n -u "$user" env \
    XDG_RUNTIME_DIR="/run/user/$uid" \
    DOCKER_HOST="unix:///run/user/$uid/docker.sock" \
    docker info --format 'DRIVER={{.CgroupDriver}} VERSION={{.CgroupVersion}}' 2>/dev/null; then
    ok "rootless_$user"
  else pending "rootless_$user"; fi
done
echo '=== MONITORING (OPTIONAL) ==='
if command -v docker >/dev/null 2>&1 && sudo -n docker ps --format '{{.Names}}' 2>/dev/null | grep -qx uptime-kuma; then
  ok uptime_kuma_running
else pending uptime_kuma_not_deployed; fi
if command -v docker >/dev/null 2>&1 && sudo -n docker ps --format '{{.Names}}' 2>/dev/null | grep -qx nginx-proxy-manager; then
  ok nginx_proxy_manager_running
else pending nginx_proxy_manager_not_deployed; fi
echo '=== REQUIRED MANUAL ACCEPTANCE ==='
echo 'CHECK=SSH_KEY_ACCESS_FROM_SECOND_SESSION'
echo 'CHECK=FIREWALL_AND_PROVIDER_FIREWALL_REVIEW'
echo 'CHECK=NO_PUBLIC_ADMIN_PORTS_81_OR_3001'
echo 'CHECK=EXTERNAL_UPTIME_MONITORING_AND_ALERT_DELIVERY'
echo 'CHECK=ENCRYPTED_OFFSITE_BACKUP_AND_ISOLATED_RESTORE_TEST'
echo 'CHECK=MEMORY_PSI_SWAP_AND_24H_PEAK_LOAD'
echo "PASS_COUNT=$PASS INCOMPLETE_COUNT=$INCOMPLETE"
if ((INCOMPLETE>0)); then echo 'VERIFICATION=INCOMPLETE'; exit 1; fi
echo 'VERIFICATION=TECHNICAL_CHECKS_PASS_MANUAL_CHECKS_PENDING'
