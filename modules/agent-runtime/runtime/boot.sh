# shellcheck shell=bash
# agent-runtime-boot: what agent-runtime.service runs once per boot. settle ends the runs the last
# shutdown or crash took down (exported, destroyed, never started again), then each eligible
# template's preflight verdict is recorded, so /run/agent-runtime/status.json answers "can this
# host admit" without root. A held instance or a NO-GO is a finding in that status, not a failed
# boot: only settle itself failing fails the unit.
USAGE='agent-runtime-boot [--state DIR] [--run DIR] [--host POLICY.json] [--profile DIR]'
usage() { echo "usage: $USAGE" >&2; exit 2; }
state=/var/lib/agent-runtime run=/run/agent-runtime host=/etc/agent-runtime/host.json
profile=/nix/var/nix/profiles/agent-runtime/templates/templates
while [ $# -gt 0 ]; do
  case $1 in
    --state) [ $# -ge 2 ] || usage; state=$2; shift 2 ;;
    --run) [ $# -ge 2 ] || usage; run=$2; shift 2 ;;
    --host) [ $# -ge 2 ] || usage; host=$2; shift 2 ;;
    --profile) [ $# -ge 2 ] || usage; profile=$2; shift 2 ;;
    *) usage ;;
  esac
done
mkdir -p "$run"
publish() {  # NAME: stdin as the world-readable $run/NAME, by rename
  cat >"$run/.$1.$$"
  chmod 0644 "$run/.$1.$$"
  mv "$run/.$1.$$" "$run/$1"
}
rc=0
if settled=$(agent-runtime-instance --state "$state" --run "$run" settle); then
  publish settle.json <<<"$settled"
else
  rc=1
  jq -nc --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{schemaVersion: 1, kind: "agent-runtime-settle", at: $at, failed: true, instances: []}' | publish settle.json
fi
jq -r '.eligibleTemplates[]' "$host" | while IFS= read -r name; do
  verdict=go
  out=$(agent-runtime-preflight --state "$state" --host "$host" --template "$profile/$name.json" --no-herdr 2>&1 </dev/null) || verdict=no-go
  jq -nc --arg t "$name" --arg v "$verdict" --arg out "$out" \
    '{template: $t, verdict: $v, failed: [$out | split("\n")[] | select(startswith("FAIL ")) | ltrimstr("FAIL ")]}'
done | jq -sc --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{at: $at, templates: .}' | publish preflight.json
agent-runtime-instance --state "$state" --run "$run" host-status --host "$host" >/dev/null
exit "$rc"
