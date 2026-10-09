#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo 'Usage: system:record task input must include label, duration, and interval.' >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
input_json=$1
label=$(jq -er '.label | strings | select(test("^[a-zA-Z0-9._-]+$"))' <<<"$input_json")
duration=$(jq -er '.duration | numbers | select(. > 0 and floor == .)' <<<"$input_json")
interval=$(jq -er '.interval | numbers | select(. > 0 and floor == .)' <<<"$input_json")
[[ $label =~ ^[a-zA-Z0-9._-]+$ ]] || usage
[[ $duration -gt 0 && $duration -le 86400 ]] || usage
[[ $interval -gt 0 && $interval -le $duration ]] || usage

state_home=${XDG_STATE_HOME:-"$HOME/.local/state"}
root="$state_home/nixos-config/performance"
stamp=$(date -u +%Y%m%dT%H%M%S%N)
out="$root/$stamp-$label"
mkdir -p "$out"

{
  printf 'started_utc=%s\n' "$(date -u --iso-8601=seconds)"
  printf 'label=%s\nduration_seconds=%s\ninterval_seconds=%s\n' "$label" "$duration" "$interval"
  printf 'kernel=%s\n' "$(uname -r)"
  printf 'nixos_version=%s\n' "$(nixos-version 2>/dev/null || echo unavailable)"
  printf 'current_system=%s\n' "$(readlink -f /run/current-system 2>/dev/null || echo unavailable)"
  printf 'cpu_model=%s\n' "$(awk -F: '/model name/ {gsub(/^ +/, "", $2); print $2; exit}' /proc/cpuinfo)"
  printf 'power_profile=%s\n' "$(powerprofilesctl get 2>/dev/null || echo unavailable)"
  printf 'git_revision=%s\n' "$(git rev-parse HEAD 2>/dev/null || echo unavailable)"
  printf '\n'
  git status --short 2>/dev/null || true
} > "$out/metadata.txt"

printf 'timestamp,cpu_some10,cpu_full10,io_some10,io_full10,memory_some10,memory_full10\n' > "$out/pressure.csv"
printf 'timestamp,sensor_readings\n' > "$out/sensors.csv"
count=$(( (duration + interval - 1) / interval ))
sar -u ALL -r -b -d -p "$interval" "$count" > "$out/sar.txt" &
sar_pid=$!
pidstat -h -u -r -d "$interval" "$count" > "$out/pidstat.txt" &
pidstat_pid=$!

for ((sample = 0; sample < count; sample++)); do
  timestamp=$(date -u --iso-8601=seconds)
  values=()
  for resource in cpu io memory; do
    values+=("$(awk '
      /some/ { for (i = 1; i <= NF; i++) if ($i ~ /^avg10=/) { split($i, value, "="); some = value[2] } }
      /full/ { for (i = 1; i <= NF; i++) if ($i ~ /^avg10=/) { split($i, value, "="); full = value[2] } }
      END { printf "%s,%s", some + 0, full + 0 }
    ' "/proc/pressure/$resource" 2>/dev/null || printf '0,0')")
  done
  printf '%s,%s,%s,%s\n' "$timestamp" "${values[0]}" "${values[1]}" "${values[2]}" >> "$out/pressure.csv"
  readings=$(sensors 2>/dev/null | tr '\n' ';' | sed 's/;*$//')
  printf '"%s","%s"\n' "$timestamp" "${readings//\"/\"\"}" >> "$out/sensors.csv"
  sleep "$interval"
done

wait "$sar_pid" || true
wait "$pidstat_pid" || true
printf 'completed_utc=%s\n' "$(date -u --iso-8601=seconds)" >> "$out/metadata.txt"
printf '%s\n' "$out"
