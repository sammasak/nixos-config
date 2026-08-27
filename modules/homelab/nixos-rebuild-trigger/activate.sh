# The switch, health gate and rollback run OUT OF BAND under a transient unit
# started by trigger.sh; see the handoff comment there for why.
# Args: PREV_SYSTEM REQUESTER REV TS

AUDIT_LOG="${AUDIT_LOG:?}"
RESULT_FILE="${RESULT_FILE:?}"
LOCK_FILE="${LOCK_FILE:?}"
HEALTH_TIMEOUT_SEC="${HEALTH_TIMEOUT_SEC:?}"
TRIGGER_USER="${TRIGGER_USER:?}"

# getent (glibc) and switch-to-configuration's helpers are not in runtimeInputs;
# the health gate and the rollback need the live system profile on PATH. This
# is an APPEND, and default.nix builds this script with inheritPath = false, so
# the search order is runtimeInputs then the system profile and nothing else.
export PATH="$PATH:/run/current-system/sw/bin"

PREV_SYSTEM="$1"
REQUESTER="$2"
REV="$3"
TS="$4"

# The lock is re-acquired here rather than inherited: flock is held via an open
# fd, and a transient unit is forked by PID 1 rather than by us, so the trigger
# service's fd 9 cannot cross the handoff. Waiting beats failing fast — the
# trigger service is exiting and about to release it, so the expected wait is
# milliseconds. That leaves a brief window in which neither unit holds the lock;
# the trigger service closes it separately by rejecting any request while this
# unit is active, so the flock is a backstop rather than the only guard.
exec 9>"$LOCK_FILE"
if ! flock -w 300 9; then
  result failed-activation-lock
  audit "result=failed-activation-lock detail=could-not-acquire-lock-within-300s prev=$PREV_SYSTEM"
  echo "nixos-rebuild-activation: could not acquire the deploy lock; staged generation NOT activated" >&2
  exit 1
fi

# Re-read the staged generation here rather than trusting a value computed
# before the handoff.
NEW_SYSTEM="$(readlink -f /nix/var/nix/profiles/system)"

# All three must pass within HEALTH_TIMEOUT_SEC seconds: the k3s API answering
# on 127.0.0.1:6443, sshd listening on :22 (or we lock ourselves out), and DNS
# resolving (this host serves DNS for the cluster).
health_check() {
  local deadline=$(( $(date +%s) + HEALTH_TIMEOUT_SEC ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local ok=1
    # 401/403/200 over TLS all mean "answering".
    curl -sk --max-time 5 -o /dev/null https://127.0.0.1:6443/healthz \
      || curl -sk --max-time 5 -o /dev/null https://127.0.0.1:6443/ || ok=0
    ss -ltn 2>/dev/null | grep -Eq ':22\b' || ok=0
    getent hosts github.com >/dev/null 2>&1 || ok=0
    if [ "$ok" -eq 1 ]; then return 0; fi
    sleep 5
  done
  return 1
}

rollback() {
  echo "nixos-rebuild-activation: ROLLING BACK to $PREV_SYSTEM" >&2
  "$PREV_SYSTEM/bin/switch-to-configuration" switch || true
  # Reset it as the boot default too, not just live.
  nixos-rebuild boot --rollback || true
}

echo "nixos-rebuild-activation: activating $NEW_SYSTEM (prev=$PREV_SYSTEM)"
if ! "$NEW_SYSTEM/bin/switch-to-configuration" switch; then
  result failed-activate-rolledback
  audit "result=failed-activate-rolledback new=$NEW_SYSTEM prev=$PREV_SYSTEM"
  rollback
  echo "nixos-rebuild-activation: activation FAILED - rolled back" >&2
  exit 1
fi

if health_check; then
  result success
  audit "result=success new=$NEW_SYSTEM"
  echo "nixos-rebuild-activation: rebuild succeeded and health checks passed"
  # Best-effort: prompt the user session to reload new Home Manager units.
  systemctl --machine="$TRIGGER_USER@" --user daemon-reload 2>/dev/null || true
else
  result failed-health-rolledback
  audit "result=failed-health-rolledback new=$NEW_SYSTEM prev=$PREV_SYSTEM"
  rollback
  echo "nixos-rebuild-activation: health checks FAILED - rolled back to previous generation" >&2
  exit 1
fi
