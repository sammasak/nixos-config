#!/usr/bin/env bash
# Grafana itself, with black-pi's dashboard provider: two dashboards provisioned from a directory of symlinks, as
# /etc/grafana-dashboards is, then one link removed; its dashboard must be gone and the other kept. With EXPECT=kept
# (the seeded disableDeletion = true) the removed one must stay, so the check tells the two settings apart.
# Usage: test-grafana-dashboard-removal.sh GRAFANA PROVIDER.json EXPECT(gone|kept)
set -eu
grafana=$1 provider=$2 expect=$3
work=$(mktemp -d "$PWD/grafana.XXXXXX")
mkdir -p "$work"/{data,logs,dashboards,src,prov/dashboards,prov/datasources,prov/plugins,prov/alerting}
for u in kept removed; do
  printf '{"uid":"%s","title":"%s","panels":[],"schemaVersion":39}\n' "$u" "$u" >"$work/src/$u.json"
  ln -s "$work/src/$u.json" "$work/dashboards/$u.json"
done
python3 -I -c 'import json, sys
p = json.load(open(sys.argv[1]))
p["options"]["path"] = sys.argv[2]
p["updateIntervalSeconds"] = 1
json.dump({"apiVersion": 1, "providers": [p]}, open(sys.argv[3], "w"))' "$provider" "$work/dashboards" "$work/prov/dashboards/homelab.yaml"
port=$((20000 + RANDOM % 20000))
cat >"$work/grafana.ini" <<INI
[server]
http_addr = 127.0.0.1
http_port = $port
[paths]
data = $work/data
logs = $work/logs
provisioning = $work/prov
[auth.anonymous]
enabled = true
org_role = Admin
[analytics]
reporting_enabled = false
check_for_updates = false
check_for_plugin_updates = false
[plugins]
preinstall_disabled = true
INI
HOME=$work "$grafana/bin/grafana" server --homepath "$grafana/share/grafana" --config "$work/grafana.ini" >"$work/out.log" 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null || true' EXIT
uids() { curl -fsS "http://127.0.0.1:$port/api/search?type=dash-db" | python3 -I -c 'import json, sys; print(" ".join(sorted(d["uid"] for d in json.load(sys.stdin))))'; }
wait_for() {
  for _ in $(seq 120); do
    [ "$(uids 2>/dev/null)" = "$1" ] && return 0
    sleep 1
  done
  echo "grafana-dashboard-removal: wanted [$1], Grafana lists [$(uids 2>/dev/null || true)]" >&2
  tail -5 "$work/out.log" >&2
  return 1
}
wait_for "kept removed"
rm "$work/dashboards/removed.json"
if [ "$expect" = gone ]; then
  wait_for "kept"
else
  sleep 5
  wait_for "kept removed"
fi
echo "removed file, dashboard $expect"
