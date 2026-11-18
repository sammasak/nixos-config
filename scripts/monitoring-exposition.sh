#!/usr/bin/env bash
# The monitoring stack's own metrics, for flake-modules/grafana-dashboards-check.nix: black-pi's Prometheus (its
# configuration and rule files, its flags) and Alertmanager (its configuration and flags), and acer's alloy-otlp (its
# unit's ExecStart as evaluated, less the token wrapper, listener and storage pointed here; fed one OTLP metric and one
# log, since its receiver counters appear only with traffic), each run on loopback with no peer reachable, and each's
# /metrics saved as OUT/<name>.prom once its ready endpoint answers and every name in NEEDS is in it.
# NEEDS is `check-grafana-dashboards.py --needs` output: "JOB NAME" for a name the panels and rules select under that
# job, "* NAME" for one only these services can provide (some appear only after a first scrape, sync or evaluation).
# A service not ready, or a name still missing, after 120 s (gate load) fails the run with the missing names and logs.
# Usage: monitoring-exposition.sh OUT PROMETHEUS PROMCONFIG 'PROMFLAGS' ALERTMANAGER AMCONFIG 'AMFLAGS' 'ALLOYEXEC' NEEDS
set -eu
out=$1 prometheus=$2 promconfig=$3 promflags=$4 alertmanager=$5 amconfig=$6 amflags=$7 alloyexec=$8 needs=$9
work=$(mktemp -d "$PWD/stack.XXXXXX")
pids=()
trap 'kill "${pids[@]}" 2>/dev/null || true' EXIT
# wait NAME URL: URL answers within 120 s
wait_for() {
  for _ in $(seq 120); do
    curl -fsS --max-time 5 -o /dev/null "$2" 2>/dev/null && return 0
    sleep 1
  done
  echo "monitoring-exposition: exporter did not start: $1: $2 did not answer in 120 s" >&2
  cat "$work/$1.log" >&2
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
# every needed name, polled from all three until present: a name selected under a job from that job's /metrics, a
# "*" name from any of them
python3 -I - "$needs" "$out" <<'EOF' || { cat "$work/prometheus.log" "$work/alertmanager.log" "$work/alloy.log" >&2; exit 1; }
import re, sys, time, urllib.request
services = {"prometheus": 19090, "alertmanager": 19093, "alloy-otlp": 19346}
files = {"prometheus": "prometheus", "alertmanager": "alertmanager", "alloy-otlp": "alloy"}
want = {}
for line in open(sys.argv[1]):
    job, name = line.split()
    want.setdefault(job, set()).add(name)
unknown = set(want) - set(services) - {"*"}
if unknown:
    sys.exit(f"monitoring-exposition: names needed from jobs not run here: {sorted(unknown)}")
missing = {}
for _ in range(120):
    bodies, have = {}, {}
    for job, port in services.items():
        try:
            bodies[job] = urllib.request.urlopen(f"http://127.0.0.1:{port}/metrics", timeout=5).read().decode()
        except OSError:
            bodies[job] = ""
        have[job] = set(re.findall(r"(?m)^[A-Za-z_:][\w:]*", bodies[job]))
    missing = {job: sorted(want.get(job, set()) - have[job]) for job in services}
    missing["*"] = sorted(want.get("*", set()) - set().union(*have.values()))
    if not any(missing.values()):
        for job, body in bodies.items():
            open(f"{sys.argv[2]}/{files[job]}.prom", "w").write(body)
        sys.exit(0)
    time.sleep(1)
sys.exit("monitoring-exposition: still missing after 120 s: "
         + "; ".join(f"{job}: {' '.join(names)}" for job, names in missing.items() if names))
EOF
