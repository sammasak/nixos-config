#!/usr/bin/env bash
# Waits for an exporter started in the background to answer with its metrics, for a check that scrapes it in a build
# sandbox (flake-modules/grafana-dashboards-check.nix). Under gate load the exporter can take longer than one fixed
# try loop allows; giving up silently then reads as metrics "provided by nothing". So: poll URL until its body holds
# every PATTERN, at most SECONDS, and stop early when the exporter (PID) has exited; save the body to OUT. Otherwise
# fail with "exporter did not start" and the exporter's log.
# Usage: wait-metrics.sh NAME URL OUT LOG PID SECONDS [PATTERN...]
set -uo pipefail

name=$1 url=$2 out=$3 log=$4 pid=$5 seconds=$6
shift 6
deadline=$((SECONDS + seconds))
while [ "$SECONDS" -lt "$deadline" ]; do
  if curl -fsS --max-time 5 -o "$out.try" "$url" 2>/dev/null; then
    missing=()
    for p in "$@"; do grep -q -- "$p" "$out.try" || missing+=("$p"); done
    if [ "${#missing[@]}" -eq 0 ]; then
      mv "$out.try" "$out"
      exit 0
    fi
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$out.try"
    cat "$log" >&2
    echo "grafana-dashboards: exporter did not start: $name (pid $pid) exited before $url answered" >&2
    exit 1
  fi
  sleep 0.5
done
rm -f "$out.try"
cat "$log" >&2
echo "grafana-dashboards: exporter did not start: $name gave no metrics at $url${missing:+ with ${missing[*]}} in $seconds s" >&2
exit 1
