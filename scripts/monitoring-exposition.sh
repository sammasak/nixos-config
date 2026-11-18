#!/usr/bin/env bash
# The monitoring stack's own metrics, for flake-modules/grafana-dashboards-check.nix: black-pi's Prometheus (its
# configuration and rule files, its flags) and Alertmanager (its configuration and flags), and acer's alloy-otlp (its
# unit's ExecStart as evaluated, less the token wrapper, listener and storage pointed here; fed one OTLP metric and one
# log, since its receiver counters appear only with traffic), each run on loopback with no peer reachable, and each's
# /metrics saved as OUT/<name>.prom once its ready endpoint answers and the series this check depends on are in it.
# Anything not there in 60 s fails the run with that service's log.
# Usage: monitoring-exposition.sh OUT PROMETHEUS PROMCONFIG 'PROMFLAGS' ALERTMANAGER AMCONFIG 'AMFLAGS' 'ALLOYEXEC'
set -eu
out=$1 prometheus=$2 promconfig=$3 promflags=$4 alertmanager=$5 amconfig=$6 amflags=$7 alloyexec=$8
work=$(mktemp -d "$PWD/stack.XXXXXX")
pids=()
trap 'kill "${pids[@]}" 2>/dev/null || true' EXIT
# wait NAME URL [PATTERN...]: URL answers, and (for /metrics) holds every PATTERN; saved as OUT/NAME.prom
wait_for() {
  local name=$1 url=$2
  shift 2
  for _ in $(seq 60); do
    if curl -fsS -o "$work/$name.try" "$url" 2>/dev/null; then
      local missing=0
      for p in "$@"; do grep -q -- "$p" "$work/$name.try" || missing=1; done
      if [ "$missing" = 0 ]; then
        [ $# = 0 ] || mv "$work/$name.try" "$out/$name.prom"
        return 0
      fi
    fi
    sleep 1
  done
  echo "monitoring-exposition: $name: $url did not answer with $* in 60 s" >&2
  cat "$work/$name.log" >&2
  return 1
}
# shellcheck disable=SC2086 # the deployed flags, one word each
"$prometheus/bin/prometheus" --config.file="$promconfig" --storage.tsdb.path="$work/tsdb" \
  --web.listen-address=127.0.0.1:19090 $promflags >"$work/prometheus.log" 2>&1 &
pids+=($!)
# shellcheck disable=SC2086
"$alertmanager/bin/alertmanager" --config.file="$amconfig" --storage.path="$work/am" \
  --web.listen-address=127.0.0.1:19093 $amflags >"$work/alertmanager.log" 2>&1 &
pids+=($!)
# the deployed argv, as alloy_otlp_argv.py rebuilds it for the alloy-otlp tests: each override hits one argument
mapfile -d '' alloy < <(python3 -I - "$alloyexec" "$work/alloy" <<'EOF'
import shlex, sys
argv = shlex.split(sys.argv[1])
if not (len(argv) > 3 and argv[0].endswith("-alloy-otlp-token") and argv[1].endswith("/bin/alloy") and argv[2] == "run"):
    sys.exit(f"alloy-otlp ExecStart is not token wrapper, alloy run ...: {argv}")
argv = argv[1:]
for prefix, new in (("--server.http.listen-addr=", "127.0.0.1:19346"), ("--storage.path=", sys.argv[2])):
    hits = [i for i, a in enumerate(argv) if a.startswith(prefix)]
    if len(hits) != 1:
        sys.exit(f"alloy-otlp ExecStart: {len(hits)} {prefix} arguments, not one: {argv}")
    argv[hits[0]] = prefix + new
sys.stdout.write("\0".join(argv) + "\0")
EOF
)
[ "${#alloy[@]}" -gt 3 ] || exit 1
OTLP_BEARER_TOKEN=check "${alloy[@]}" >"$work/alloy.log" 2>&1 &
pids+=($!)
wait_for prometheus http://127.0.0.1:19090/-/ready
wait_for alertmanager http://127.0.0.1:19093/-/ready
wait_for alloy http://127.0.0.1:19346/-/ready
now=$(date +%s)000000000
resource='"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"claude-code"}}]}'
post() {
  curl -fsS -o /dev/null -H 'Authorization: Bearer check' -H 'Content-Type: application/json' -d "$2" \
    "http://127.0.0.1:4318/v1/$1"
}
post metrics '{"resourceMetrics":[{'"$resource"',"scopeMetrics":[{"metrics":[{"name":"claude_code.cost.usage","unit":"USD","sum":{"aggregationTemporality":2,"isMonotonic":true,"dataPoints":[{"asDouble":1,"timeUnixNano":"'"$now"'"}]}}]}]}]}'
post logs '{"resourceLogs":[{'"$resource"',"scopeLogs":[{"logRecords":[{"timeUnixNano":"'"$now"'","body":{"stringValue":"check"}}]}]}]}'
# the late series: the notifier's per-Alertmanager counters, the TSDB's (samples appended needs a first rule
# evaluation, up to the 30 s interval), the rule groups', the receiver's
wait_for prometheus http://127.0.0.1:19090/metrics '^prometheus_notifications_errors_total{' \
  '^prometheus_tsdb_head_series ' '^prometheus_rule_group_last_duration_seconds{' '^prometheus_tsdb_head_samples_appended_total'
wait_for alertmanager http://127.0.0.1:19093/metrics '^alertmanager_notifications_total{'
wait_for alloy http://127.0.0.1:19346/metrics '^otelcol_receiver_accepted_metric_points_total' \
  '^otelcol_receiver_accepted_log_records_total'
