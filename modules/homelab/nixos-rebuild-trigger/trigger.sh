TRIGGER_DIR="${TRIGGER_DIR:?}"
TRIGGER_FILE="${TRIGGER_FILE:?}"
TRIGGER_GROUP="${TRIGGER_GROUP:?}"
LOCK_FILE="${LOCK_FILE:?}"
FLAKE_REF="${FLAKE_REF:?}"
HOST_ATTR="${HOST_ATTR:?}"
ACTIVATION_UNIT="${ACTIVATION_UNIT:?}"
ACTIVATE_SCRIPT="${ACTIVATE_SCRIPT:?}"
HEALTH_TIMEOUT_SEC="${HEALTH_TIMEOUT_SEC:?}"
TRIGGER_USER="${TRIGGER_USER:?}"

# Consume the request FILE only, and first, so the path unit cannot re-arm into
# a loop. The directory must survive: it is the trigger surface itself, and /run
# tmpfiles rules are re-applied only at boot, so removing it here would disable
# the trigger until the next reboot.
REQUEST_RAW="$(cat "$TRIGGER_FILE" 2>/dev/null || true)"
rm -f "$TRIGGER_FILE"

# Every status write below targets this directory, and `set -e` would abort the
# run before any audit trail existed if it were missing. Re-asserting is
# idempotent.
install -d -m 0770 -o root -g "$TRIGGER_GROUP" "$TRIGGER_DIR"

REQUESTER="$(printf '%s\n' "$REQUEST_RAW" | sed -n 's/^requester=//p' | head -1 | tr -dc '[:alnum:]._-' | cut -c1-128)"
REV="$(printf '%s\n' "$REQUEST_RAW" | sed -n 's/^rev=//p' | head -1 | tr -dc '[:alnum:]' | cut -c1-64)"
: "${REQUESTER:=unknown}"
TS="$(date -Iseconds)"

# A floating ref (branch or tag) is REJECTED so the deployed tree is immutable,
# reproducible and auditable.
if ! printf '%s' "$REV" | grep -Eq '^[0-9a-f]{40}$'; then
  result rejected-bad-rev
  audit "result=rejected-bad-rev detail=rev-must-be-40-hex-sha"
  echo "nixos-rebuild-trigger: REJECTED - 'rev' must be a full 40-char git SHA (got: '$REV')" >&2
  exit 1
fi

FLAKE="$FLAKE_REF/$REV#$HOST_ATTR"
result running
audit "result=running flake=$FLAKE"
echo "nixos-rebuild-trigger: requester=$REQUESTER rebuilding PINNED $FLAKE"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  result rejected-locked
  audit "result=rejected-locked detail=another-deploy-in-progress"
  echo "nixos-rebuild-trigger: REJECTED - another deploy holds the lock" >&2
  exit 1
fi

# The lock does not cover the window between this unit exiting and the
# activation unit re-acquiring it (see activate.sh), so reject outright while an
# activation is still in flight.
if systemctl is-active --quiet "$ACTIVATION_UNIT.service"; then
  result rejected-activating
  audit "result=rejected-activating detail=activation-already-in-flight"
  echo "nixos-rebuild-trigger: REJECTED - $ACTIVATION_UNIT.service is still activating a previous deploy" >&2
  exit 1
fi

# Captured HERE, before anything is activated, so the activation unit rolls back
# to precisely this generation.
PREV_SYSTEM="$(readlink -f /run/current-system)"
echo "nixos-rebuild-trigger: current generation = $PREV_SYSTEM"

# Stages as the boot default; does NOT activate live.
if ! nixos-rebuild boot --flake "$FLAKE"; then
  result failed-build
  audit "result=failed-build flake=$FLAKE"
  echo "nixos-rebuild-trigger: build/boot staging FAILED" >&2
  exit 1
fi

NEW_SYSTEM="$(readlink -f /nix/var/nix/profiles/system)"

# This unit is part of the configuration being activated, so it must not run the
# switch itself: switch-to-configuration's stop phase would SIGTERM this very
# script mid-switch, leaving units stopped and the health gate and rollback
# unreachable. systemd-run asks PID 1 to fork the activation, so it lives
# outside this unit's cgroup; a transient unit is in no generation's unit set,
# so the switch never stops it. --collect reaps it, success or failure.
# See vault: homelab/decisions/ADR-024-nixos-rebuild-trigger-security-model.md
echo "nixos-rebuild-trigger: handing activation of $NEW_SYSTEM to $ACTIVATION_UNIT.service"
systemd-run \
  --collect \
  --unit="$ACTIVATION_UNIT" \
  --quiet \
  --description="Detached activation + health gate for a board-worker nixos-rebuild" \
  --property=SyslogIdentifier="$ACTIVATION_UNIT" \
  --setenv=AUDIT_LOG="$AUDIT_LOG" \
  --setenv=RESULT_FILE="$RESULT_FILE" \
  --setenv=LOCK_FILE="$LOCK_FILE" \
  --setenv=HEALTH_TIMEOUT_SEC="$HEALTH_TIMEOUT_SEC" \
  --setenv=TRIGGER_USER="$TRIGGER_USER" \
  "$ACTIVATE_SCRIPT" "$PREV_SYSTEM" "$REQUESTER" "$REV" "$TS"

# NOT a terminal state: the transient unit writes the final result.
result staged-and-activating
audit "result=staged-and-activating new=$NEW_SYSTEM prev=$PREV_SYSTEM handoff=$ACTIVATION_UNIT.service"
echo "nixos-rebuild-trigger: build staged; $ACTIVATION_UNIT.service owns the switch, health gate and rollback from here"
