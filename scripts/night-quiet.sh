#!/usr/bin/env bash
# Sets this host's CPU for the time of day: from START to END (the fleet's night, sam.fleet.night; it may wrap
# midnight) intel_pstate runs with turbo off and max_perf_pct at PCT, otherwise turbo on and 100. The state comes from
# the clock now, not from which edge fired last, so a boot or deploy at any hour lands right; the night-quiet units
# run it at boot and at both edges (modules/core/power-schedule.nix). Fails, naming the path, if intel_pstate is not
# there. QUIET_NOW (HH:MM) and QUIET_SYSFS override the clock and the sysfs directory (scripts/test-night-quiet.py).
# Usage: night-quiet.sh START END PCT
set -euo pipefail
start=$1 end=$2 pct=$3
sys=${QUIET_SYSFS:-/sys/devices/system/cpu/intel_pstate}
now=${QUIET_NOW:-$(date +%H:%M)}
minutes() {
  [[ $1 =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]] || { echo "night-quiet: not HH:MM: $1" >&2; exit 2; }
  echo $((10#${BASH_REMATCH[1]} * 60 + 10#${BASH_REMATCH[2]}))
}
# one per line: on one line only the last substitution's status counts, and set -e would miss a bad time
n=$(minutes "$now")
s=$(minutes "$start")
e=$(minutes "$end")
[ "$s" -ne "$e" ] || { echo "night-quiet: the night starts and ends at $start" >&2; exit 2; }
if [ "$s" -lt "$e" ]; then
  if [ "$n" -ge "$s" ] && [ "$n" -lt "$e" ]; then night=1; else night=0; fi
elif [ "$n" -ge "$s" ] || [ "$n" -lt "$e" ]; then
  night=1
else
  night=0
fi
for f in no_turbo max_perf_pct; do
  [ -w "$sys/$f" ] || { echo "night-quiet: $sys/$f is not writable: no intel_pstate here" >&2; exit 1; }
done
if [ "$night" = 1 ]; then
  echo 1 >"$sys/no_turbo"
  echo "$pct" >"$sys/max_perf_pct"
  state=quiet
else
  echo 100 >"$sys/max_perf_pct"
  echo 0 >"$sys/no_turbo"
  state=day
fi
echo "night-quiet: $state at $now (night $start-$end): no_turbo=$(<"$sys/no_turbo") max_perf_pct=$(<"$sys/max_perf_pct")"
