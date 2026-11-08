#!/usr/bin/env bash
# Read-only MSI host snapshot for sizing agent-runtime admission policy (#185).
# Run during the normal power window. This prints no environment variables,
# command arguments, credentials, model contents, or filesystem file listings.
set -uo pipefail

section() {
  printf '\n## %s\n' "$1"
}

section 'host'
printf 'timestamp='; date --iso-8601=seconds 2>/dev/null || date
printf 'hostname='; hostname --fqdn 2>/dev/null || hostname
printf 'kernel='; uname -r
awk -F= '/^PRETTY_NAME=/ {gsub(/"/, "", $2); print "os=" $2; exit}' /etc/os-release 2>/dev/null || true

section 'cpu'
printf 'available_processors='; nproc 2>/dev/null || printf 'unavailable\n'
awk -F: '/^model name[[:space:]]*:/ {sub(/^[[:space:]]+/, "", $2); print "model=" $2; exit}' /proc/cpuinfo 2>/dev/null || true

section 'memory'
awk '/^(MemTotal|MemAvailable|SwapTotal|SwapFree):/ {print}' /proc/meminfo 2>/dev/null || true

section 'storage'
if command -v lsblk >/dev/null 2>&1; then
  lsblk --bytes --noheadings --output NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL 2>/dev/null || true
fi
for path in / /var /var/lib /var/lib/agent-runtime /var/lib/rancher/k3s /var/lib/ollama; do
  [[ -e "$path" ]] || continue
  printf 'path=%s\n' "$path"
  findmnt --noheadings --output SOURCE,FSTYPE,TARGET --target "$path" 2>/dev/null || true
  df --human-readable --output=source,size,used,avail,pcent,target "$path" 2>/dev/null | tail -n 1 || true
done

section 'services'
for unit in k3s.service ollama.service agent-runtime-instance.service herdr.service; do
  if command -v systemctl >/dev/null 2>&1; then
    printf 'unit=%s ' "$unit"
    systemctl show "$unit" --no-pager \
      --property=LoadState --property=ActiveState --property=SubState \
      --property=MemoryCurrent --property=CPUUsageNSec 2>/dev/null \
      | tr '\n' ' '
    printf '\n'
  fi
done

section 'largest_processes'
if command -v ps >/dev/null 2>&1; then
  ps --no-headers --format=comm,rss,pcpu --sort=-rss 2>/dev/null | head -n 12 || true
fi

section 'service_cgroup_snapshot'
if command -v systemd-cgtop >/dev/null 2>&1; then
  systemd-cgtop --batch --iterations=1 --depth=4 --order=memory 2>/dev/null | head -n 30 || true
fi
