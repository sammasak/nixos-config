#!/usr/bin/env bash
# The in-guest isolation probe (nixos-config#198) must discriminate. It runs here against a
# local emulation of the instance policy: a new user, network and mount namespace with every
# capability dropped, no_new_privs, the Nix daemon socket hidden and no SSH agent. Under that
# emulation it must pass. With exactly one property broken it must fail, on that property's
# own line. The real nspawn positive case is the VM acceptance test.
set -euo pipefail
cd "$(dirname "$0")/.."

# ISOLATION_PROBE swaps in another probe, to check this test rejects a non-discriminating one.
probe=${ISOLATION_PROBE:-$PWD/scripts/agent-runtime-isolation-probe.sh}
port=47011
fail() { printf 'isolation-probe-test: %s\n' "$1" >&2; exit 1; }
work=$(mktemp -d)
nc -lk 127.0.0.1 "$port" >/dev/null 2>&1 &
listener=$!
trap 'kill "$listener" 2>/dev/null || true; rm -rf "$work"' EXIT
for _ in $(seq 50); do (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && break; sleep 0.1; done
(exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null || fail "the host-side listener never came up"

# run <name> <netns: own|shared> <caps: drop|keep> <daemon: hide|show> <agent: none|set>
run() {
  local name=$1 net=$2 caps=$3 daemon=$4 agent=$5
  local unshare=(unshare -r -m) inner=()
  [[ $net == own ]] && unshare+=(-n)
  [[ $daemon == hide ]] && inner+=('{ [ ! -d /nix/var/nix/daemon-socket ] || mount -t tmpfs none /nix/var/nix/daemon-socket; } &&')
  local exec_probe=(bash "$probe" 127.0.0.1 "$port")
  [[ $caps == drop ]] && exec_probe=(setpriv --bounding-set=-all --inh-caps=-all --no-new-privs -- "${exec_probe[@]}")
  local env_args=(env -u SSH_AUTH_SOCK TMPDIR="$work")
  [[ $agent == set ]] && env_args+=(SSH_AUTH_SOCK=/run/user/agent.sock)
  local cmd
  printf -v cmd '%q ' "${env_args[@]}" "${exec_probe[@]}"
  set +e
  "${unshare[@]}" bash -c "${inner[*]} exec $cmd" >"$work/$name.log" 2>&1
  echo $? >"$work/$name.exit"
  set -e
}

expect_pass() {
  if [[ $(cat "$work/$1.exit") != 0 ]] || ! grep -qx 'isolation-probe: ok' "$work/$1.log"; then
    cat "$work/$1.log" >&2
    fail "$1: the probe did not pass under the emulated policy"
  fi
}
expect_fail() {
  local name=$1 line=$2
  if [[ $(cat "$work/$name.exit") == 0 ]] || grep -q 'isolation-probe: ok' "$work/$name.log" \
    || ! grep -qF "FAIL   $line" "$work/$name.log"; then
    cat "$work/$name.log" >&2
    fail "$name: the probe did not fail on '$line'"
  fi
}

run policy own drop hide none
run shared-netns shared drop hide none
run kept-caps own keep hide none
run daemon-socket own drop show none
run ssh-agent own drop hide set

expect_pass policy
expect_fail shared-netns 'allowed: exec 3<>/dev/tcp/127.0.0.1/'
expect_fail shared-netns 'interfaces: '
expect_fail kept-caps 'CapBnd '
expect_fail kept-caps 'NoNewPrivs 0'
expect_fail daemon-socket 'nix daemon socket reachable'
expect_fail ssh-agent 'SSH_AUTH_SOCK set'
echo "isolation-probe-test: passes under the emulated policy; fails on a shared netns, kept capabilities, a visible daemon socket and an SSH agent"
