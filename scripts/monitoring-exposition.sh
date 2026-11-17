#!/usr/bin/env bash
# The monitoring stack's own metrics, for flake-modules/grafana-dashboards-check.nix: black-pi's Prometheus (its
# configuration and rule files, its flags) and Alertmanager (its configuration), and acer's alloy-otlp (its config
# file, fed one OTLP metric and one log, since its receiver counters appear only with traffic), each run on loopback
# with no peer reachable, and each's /metrics saved as OUT/<name>.prom. A service that answers no /metrics in 60 s
# fails the run. Usage: monitoring-exposition.sh OUT PROMETHEUS PROMCONFIG 'PROMFLAGS' ALERTMANAGER AMCONFIG ALLOY ALLOYCFG
set -eu
out=$1 prometheus=$2 promconfig=$3 promflags=$4 alertmanager=$5 amconfig=$6 alloy=$7 alloycfg=$8
work=$(mktemp -d "$PWD/stack.XXXXXX")
pids=()
trap 'kill "${pids[@]}" 2>/dev/null || true' EXIT
scrape() {
  for _ in $(seq 60); do
    curl -fsS -o "$out/$1.prom" "$2" 2>/dev/null && return 0
    sleep 1
  done
  echo "monitoring-exposition: $1 answered no $2" >&2
  cat "$work/$1.log" >&2
  return 1
}
# shellcheck disable=SC2086 # the deployed flags, one word each
"$prometheus/bin/prometheus" --config.file="$promconfig" --storage.tsdb.path="$work/tsdb" \
  --web.listen-address=127.0.0.1:19090 $promflags >"$work/prometheus.log" 2>&1 &
pids+=($!)
"$alertmanager/bin/alertmanager" --config.file="$amconfig" --storage.path="$work/am" \
  --web.listen-address=127.0.0.1:19093 --cluster.listen-address= >"$work/alertmanager.log" 2>&1 &
pids+=($!)
sed 's/0\.0\.0\.0:/127.0.0.1:/g' "$alloycfg" >"$work/otlp.alloy"
OTLP_BEARER_TOKEN=check "$alloy/bin/alloy" run --stability.level=experimental --disable-reporting \
  --server.http.listen-addr=127.0.0.1:19346 --storage.path="$work/alloy" "$work/otlp.alloy" >"$work/alloy.log" 2>&1 &
pids+=($!)
for _ in $(seq 60); do curl -fsS -o /dev/null http://127.0.0.1:19346/-/ready 2>/dev/null && break; sleep 1; done
now=$(date +%s)000000000
resource='"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"claude-code"}}]}'
post() {
  curl -fsS -o /dev/null -H 'Authorization: Bearer check' -H 'Content-Type: application/json' -d "$2" \
    "http://127.0.0.1:4318/v1/$1"
}
post metrics '{"resourceMetrics":[{'"$resource"',"scopeMetrics":[{"metrics":[{"name":"claude_code.cost.usage","unit":"USD","sum":{"aggregationTemporality":2,"isMonotonic":true,"dataPoints":[{"asDouble":1,"timeUnixNano":"'"$now"'"}]}}]}]}]}'
post logs '{"resourceLogs":[{'"$resource"',"scopeLogs":[{"logRecords":[{"timeUnixNano":"'"$now"'","body":{"stringValue":"check"}}]}]}]}'
# a few rule evaluations and scrapes
sleep 10
scrape prometheus http://127.0.0.1:19090/metrics
scrape alertmanager http://127.0.0.1:19093/metrics
scrape alloy http://127.0.0.1:19346/metrics
grep -q '^otelcol_receiver_accepted_metric_points_total' "$out/alloy.prom" || {
  echo "monitoring-exposition: alloy-otlp counted no accepted metric point" >&2
  exit 1
}
