#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 1 ]] || { echo 'Expected devenv task input JSON.' >&2; exit 2; }
input_json=$1
label=$(jq -er '.label | strings | select(test("^[a-zA-Z0-9._-]+$"))' <<<"$input_json")
command=$(jq -er '.command | strings | select(length > 0)' <<<"$input_json")
runs=$(jq -er '.runs | numbers | select(. >= 3 and . <= 30 and floor == .)' <<<"$input_json")
warmup=$(jq -er '.warmup | numbers | select(. >= 0 and . <= 10 and floor == .)' <<<"$input_json")

state_home=${XDG_STATE_HOME:-"$HOME/.local/state"}
root="$state_home/nixos-config/performance"
stamp=$(date -u +%Y%m%dT%H%M%S%N)
out="$root/$stamp-$label"
mkdir -p "$out"
printf '%s\n' "$command" > "$out/command.txt"

power_profile=$(powerprofilesctl get 2>/dev/null || echo unavailable)
ac_online=unknown
for supply in /sys/class/power_supply/*; do
  [[ -r "$supply/type" && -r "$supply/online" ]] || continue
  if [[ $(<"$supply/type") == Mains ]]; then ac_online=$(<"$supply/online"); break; fi
done
jq -n \
  --arg started "$(date -u --iso-8601=seconds)" \
  --arg host "$(uname -n)" \
  --arg kernel "$(uname -r)" \
  --arg system "$(readlink -f /run/current-system 2>/dev/null || echo unavailable)" \
  --arg cpu "$(awk -F: '/model name/ {gsub(/^ +/, "", $2); print $2; exit}' /proc/cpuinfo)" \
  --arg powerProfile "$power_profile" \
  --arg acOnline "$ac_online" \
  --arg revision "$(git rev-parse HEAD 2>/dev/null || echo unavailable)" \
  --arg label "$label" --arg command "$command" \
  --argjson runs "$runs" --argjson warmup "$warmup" \
  '{startedUtc:$started, host:$host, kernel:$kernel, currentSystem:$system,
    cpu:$cpu, powerProfile:$powerProfile, acOnline:$acOnline,
    gitRevision:$revision, label:$label, command:$command, runs:$runs, warmup:$warmup}' \
  > "$out/metadata.json"
git status --short > "$out/git-status.txt" 2>/dev/null || true

capture_context() {
  local destination=$1
  {
    printf 'captured_utc=%s\n' "$(date -u --iso-8601=seconds)"
    printf '\n[uptime]\n'; uptime
    printf '\n[pressure]\n'; cat /proc/pressure/{cpu,io,memory} 2>/dev/null || true
    printf '\n[sensors]\n'; sensors 2>/dev/null || true
  } > "$destination"
}

capture_context "$out/context-before.txt"
hyperfine --shell bash --warmup "$warmup" --runs "$runs" \
  --export-json "$out/results.json" "$command" 2>&1 | tee "$out/hyperfine.txt"
capture_context "$out/context-after.txt"
printf 'Results: %s\n' "$out"
