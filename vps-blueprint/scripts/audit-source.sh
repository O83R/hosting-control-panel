#!/usr/bin/env bash
# READ ONLY. Audit structure, NOT configuration secrets. Do not publish raw output.
set -uo pipefail
echo '=== VPS SOURCE AUDIT (NONSECRET) ==='
echo 'MODE=READ_ONLY NO_CHANGES=YES'
echo 'DATE_UTC=' "$(date -u +%FT%TZ)"
echo 'HOSTNAME=' "$(hostname -s)"
echo '=== OS / CGROUP ==='
grep -E '^(NAME|VERSION_ID|VERSION_CODENAME)=' /etc/os-release
stat -fc 'CGROUP_FS=%T' /sys/fs/cgroup
echo '=== CPU/MEMORY/DISKS ==='
nproc
free -h
df -hT -x tmpfs -x devtmpfs
echo '=== NETWORK PORTS (NO ADDRESSES) ==='
ss -ltnH | awk '{n=split($4,a,":"); print "LISTEN_PORT=" a[n]}' | sort -u
echo '=== ROOTLESS USERS / LINGER / CONTAINER COUNTS ==='
for user in $(ps -eo user=,comm= | awk '$2=="dockerd" && $1!="root"{print $1}' | sort -u); do
  echo "USER=$user"
  uid="$(id -u "$user" 2>/dev/null)" || continue
  loginctl show-user "$user" -p Linger -p State 2>/dev/null || :
  sudo -n -u "$user" env XDG_RUNTIME_DIR="/run/user/$uid" \
    DOCKER_HOST="unix:///run/user/$uid/docker.sock" \
    docker ps --format 'RUNNING={{.Names}} RESTART_CHECK=INSPECT_SEPARATELY' \
    2>/dev/null || echo 'DOCKER_ACCESS=UNAVAILABLE'
done
echo '=== ROOT ENGINE CONTAINERS (NAMES ONLY) ==='
sudo -n docker ps --format 'RUNNING={{.Names}}' 2>/dev/null || echo 'ROOT_ACCESS=UNAVAILABLE'
echo '=== BACKUP SERVICE STATUS, NOT CONTENTS ==='
for unit in vps-infrastructure-backup.service wf-water-factories-backup.service; do
  echo "UNIT=$unit"
  systemctl show "$unit" -p LoadState -p Result -p ExecMainStatus --no-pager
done
echo '=== MONITORING OBSERVATION ==='
sudo -n docker ps --filter name=uptime-kuma --format 'MONITOR={{.Names}} {{.Status}}' 2>/dev/null || :
echo '=== AUDIT COMPLETE ==='
echo 'WARNING=OUTPUT_MAY_INCLUDE_HOSTNAMES_AND_PROJECT_NAMES; REVIEW_BEFORE_SHARING'
