# shellcheck shell=bash
# agent-runtime-preflight: the runbook's no-go list (docs/agent-runtime-runbook.md) as one read-only
# check before a pilot run (#165). Every check prints PASS or FAIL with what it saw; a check that
# cannot be evaluated is a FAIL, never a pass. Exit 0 only when every check passes. It changes
# nothing: no create, no reservation, no unit (the user-namespace probe is a throwaway `unshare`).
USAGE='agent-runtime-preflight [--state DIR] [--host POLICY.json] --template MANIFEST.json [--herdr-user USER]'
usage() { echo "usage: $USAGE" >&2; exit 2; }
state=/var/lib/agent-runtime host=/etc/agent-runtime/host.json template='' herdr_user=${SUDO_USER:-}
while [ $# -gt 0 ]; do
  case $1 in
    --state) [ $# -ge 2 ] || usage; state=$2; shift 2 ;;
    --host) [ $# -ge 2 ] || usage; host=$2; shift 2 ;;
    --template) [ $# -ge 2 ] || usage; template=$2; shift 2 ;;
    --herdr-user) [ $# -ge 2 ] || usage; herdr_user=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$template" ] || usage
failed=0
pass() { echo "PASS $1: $2"; }
nogo() { echo "FAIL $1: $2"; failed=1; }

if [ -r "$host" ] && [ -r "$template" ] && jq -e . "$host" "$template" >/dev/null 2>&1; then
  name=$(jq -r .template.name "$template")
  pass inputs "host policy $host, template $name ($template)"
else
  nogo inputs "cannot read the host policy $host or the template $template as JSON"
  exit 1
fi

# --- namespaces and the UID mapping the instance needs
n=$(cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo 0)
if [ "$n" -gt 0 ] && unshare --user --map-root-user true 2>/dev/null; then
  pass user-namespaces "max_user_namespaces=$n, a mapped user namespace can be created"
else
  nogo user-namespaces "max_user_namespaces=$n or unshare --user failed: start would fail closed"
fi
missing=''
for f in /proc/self/ns/{mnt,pid,ipc,uts,net}; do [ -e "$f" ] || missing="$missing $f"; done
if [ -z "$missing" ]; then pass namespaces "mount, pid, ipc, uts and net namespaces present"
else nogo namespaces "missing:$missing"; fi
# instances map 64 ranges of 65536 ids from 1048576; no host account may live in them
lo=1048576 hi=$((1048576 + 64 * 65536))
clash=$( { getent passwd; getent group; } | awk -F: -v lo="$lo" -v hi="$hi" '$3 >= lo && $3 < hi {print $1 ":" $3}' | head -3 || true)
sub=$(awk -F: -v lo="$lo" -v hi="$hi" '$2 < hi && $2 + $3 > lo {print FILENAME ":" $1}' /etc/subuid /etc/subgid 2>/dev/null | head -3 || true)
if [ -z "$clash$sub" ]; then
  pass uid-ranges "no account, subuid or subgid entry inside $lo..$((hi - 1))"
else
  nogo uid-ranges "ids inside the instance ranges: $clash $sub"
fi

# --- vm.panic_on_oom: 2 panics the host on any cgroup OOM
p=$(cat /proc/sys/vm/panic_on_oom 2>/dev/null || echo unknown)
case $p in
  0 | 1) pass panic-on-oom "vm.panic_on_oom=$p" ;;
  *) nogo panic-on-oom "vm.panic_on_oom=$p (a cgroup OOM would panic the host; the runtime needs 0 or 1)" ;;
esac

# --- memory and disk against the reserve, the way `create` admits
mem=$(jq -r .policies.resources.memoryMiB "$template")
disk=$(jq -r '[.filesystem.workspaceBudget.sizeMiB, .filesystem.home.sizeMiB, .filesystem.tmp.sizeMiB, .filesystem.cache.sizeMiB, .filesystem.output.sizeMiB] | add' "$template")
mem_reserve=$(jq -r .reserve.memoryMiB "$host") disk_reserve=$(jq -r .reserve.diskMiB "$host")
mem_total=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
mem_available=$(awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo)
if [ -d "$state" ] && [ ! -r "$state" ]; then
  nogo reservations "$state is not readable (run as root)"
  mem_used=0
else
  mem_used=$(cat "$state"/*/reservation 2>/dev/null | awk '{s += $1} END {print s + 0}' || true)
fi
if [ $((mem_used + mem)) -le $((mem_total - mem_reserve)) ] && [ $((mem_available - mem)) -ge "$mem_reserve" ]; then
  pass memory "MemAvailable $mem_available MiB - $mem MiB instance >= $mem_reserve MiB reserve; reserved $mem_used+$mem <= $mem_total-$mem_reserve MiB"
else
  nogo memory "MemAvailable $mem_available MiB - $mem MiB instance under the $mem_reserve MiB reserve, or reserved $mem_used+$mem over $mem_total-$mem_reserve MiB"
fi
probe=$state; [ -d "$probe" ] || probe=$(dirname "$state")
disk_free=$(df --output=avail -BM "$probe" 2>/dev/null | tail -1 | tr -dc 0-9 || true)
if [ -n "$disk_free" ] && [ $((disk + disk_reserve)) -le "$disk_free" ]; then
  pass disk "$disk_free MiB free under $probe >= $disk MiB volumes + $disk_reserve MiB reserve"
else
  nogo disk "${disk_free:-unknown} MiB free under $probe, need $disk MiB volumes + $disk_reserve MiB reserve"
fi

# --- the template is eligible and the host admits at all
if jq -e --arg n "$name" '.enable and (.eligibleTemplates | index($n))' "$host" >/dev/null; then
  pass eligible "$name is eligible, at most $(jq -r .maxConcurrentInstances "$host") instance(s)"
else
  nogo eligible "the host policy does not enable $name"
fi

# --- Herdr answers (the handoff goes through it); as the user whose server it is when run under sudo
herdr_cmd=(herdr agent list)
[ -z "$herdr_user" ] || [ "$(id -u)" != 0 ] || herdr_cmd=(runuser -u "$herdr_user" -- herdr agent list)
if out=$(timeout 10 "${herdr_cmd[@]}" 2>&1) && jq -e '.result.agents' >/dev/null 2>&1 <<<"$out"; then
  pass herdr "server answers (${herdr_user:-$(id -un)}): $(jq '.result.agents | length' <<<"$out") agent(s)"
else
  nogo herdr "herdr agent list failed as ${herdr_user:-$(id -un)}: $(head -c 160 <<<"$out")"
fi

# --- no instance running or unresolved: the pilot runs alone, and an ambiguous run is decided by hand
if [ ! -d "$state" ]; then
  pass instances "no state directory yet ($state)"
elif st=$(agent-runtime-instance --state "$state" status 2>/dev/null); then
  busy=$(jq -r '[.[] | select(.state | IN("running", "starting", "cancelling", "ambiguous", "incomplete")) | "\(.id)=\(.state)"] | join(" ")' <<<"$st")
  if [ -z "$busy" ]; then pass instances "$(jq length <<<"$st") instance(s), none running or unresolved"
  else nogo instances "running or unresolved: $busy"; fi
else
  nogo instances "agent-runtime-instance status failed (run as root)"
fi

if [ "$failed" = 0 ]; then echo "preflight: go"; else echo "preflight: NO-GO"; fi
exit "$failed"
