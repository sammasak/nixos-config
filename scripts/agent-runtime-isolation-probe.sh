#!/usr/bin/env bash
# In-guest isolation probe for the Factum acceptance test (nixos-config#198), run inside an
# agent-runtime instance through its request argv. Bash builtins only, so the result cannot
# depend on which tools the project's environment puts on PATH.
#
#   bash agent-runtime-isolation-probe.sh [TARGET_IP] [PORT]
#
# TARGET_IP:PORT is a listener the caller runs in the netns the instance must NOT share. A
# connect to it succeeds wherever that netns is shared, so the check fails on a broken network
# policy instead of passing for lack of a route (an offline VM refuses 1.1.1.1 either way).
# Exit 0 and `isolation-probe: ok` only when every check holds.
target=${1:-10.213.0.1}
port=${2:-47011}
fail=0
ok() { echo "ok     $1"; }
bad() { echo "FAIL   $1"; fail=1; }
deny() { if (eval "$1") 2>/dev/null; then bad "allowed: $1"; else echo "denied $1"; fi; }

# /proc/self/net/dev is the probing process's own netns; /sys/class/net shows the netns sysfs
# was mounted in, which a shared /sys would misreport.
nets=()
while IFS=: read -r name _; do
  name=${name// /}
  [[ $name == Inter-* || $name == face* || -z $name ]] || nets+=("$name")
done </proc/self/net/dev
if [[ ${nets[*]} == lo ]]; then ok "only loopback"; else bad "interfaces: ${nets[*]}"; fi
while IFS=$':\t ' read -r key value _; do
  case $key in
    CapInh | CapPrm | CapEff | CapBnd | CapAmb)
      if [[ $value =~ ^0+$ ]]; then ok "$key empty"; else bad "$key $value"; fi ;;
    NoNewPrivs)
      if [[ $value == 1 ]]; then ok "no_new_privs"; else bad "NoNewPrivs $value"; fi ;;
  esac
done </proc/self/status
if [[ ! -e /run/agent-runtime/credentials ]]; then ok "no credential mount"; else bad "credential mount present"; fi
if [[ ! -e /nix/var/nix/daemon-socket/socket ]]; then ok "no nix daemon socket"; else bad "nix daemon socket reachable"; fi
if [[ -z ${SSH_AUTH_SOCK:-} ]]; then ok "no ssh agent"; else bad "SSH_AUTH_SOCK set"; fi
if (: >"${TMPDIR:-/tmp}/agent-runtime-isolation-probe"); then ok "tmp writable"; else bad "tmp not writable"; fi
deny ': >/nix/store/agent-runtime-isolation-probe'
deny ': >>/etc/agent-runtime/execution-request.json'
deny "exec 3<>/dev/tcp/$target/$port"
if [[ $fail == 0 ]]; then echo "isolation-probe: ok"; fi
exit "$fail"
