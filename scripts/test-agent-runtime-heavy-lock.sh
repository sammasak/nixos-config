#!/usr/bin/env bash
# The heavy-work lock is taken once per heavy script (nixos-config#198): a bare run holds it from
# its first step, a run under a caller's `flock` does not deadlock, and a contended lock is
# waited for, not skipped. It also checks the Factum acceptance script takes the lock before host
# preparation and nowhere else.
set -euo pipefail
cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
lock="$work/heavy.lock"
: >"$lock"
fail() { printf 'heavy-lock-test: %s\n' "$1" >&2; exit 1; }

# A stand-in heavy script: take the lock, then report whether an outside process can take it.
cat >"$work/heavy.sh" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail
source "$PWD/scripts/lib/heavy-lock.sh"
heavy_lock_hold "$lock" "\${WAIT:-5}" bash "\$0" "\$@"
if flock -n "$lock" true; then echo unlocked; else echo locked; fi
SCRIPT

# 1. bare: the script holds the lock for its whole run.
out=$(timeout 30 bash "$work/heavy.sh") || fail "bare run failed"
[ "$out" = locked ] || fail "bare run did not hold the lock (got '$out')"

# 2. nested: a caller already holds it; the script must not wait on itself.
out=$(timeout 30 flock "$lock" bash "$work/heavy.sh") || fail "nested run deadlocked or failed"
[ "$out" = locked ] || fail "nested run ran outside the caller's lock (got '$out')"

# 3. contended: another holder keeps it; the script waits WAIT seconds, then gives up.
flock "$lock" sleep 5 &
holder=$!
sleep 0.5
if WAIT=1 timeout 30 bash "$work/heavy.sh" >/dev/null 2>&1; then
  fail "contended run did not wait for the lock"
fi
wait "$holder"

# 4. the Factum acceptance script: one acquisition, before host preparation.
factum=scripts/test-agent-runtime-factum-devenv-projection.sh
lock_line=$(grep -n 'heavy_lock_hold ' "$factum" | head -n1 | cut -d: -f1 || true)
prep_line=$(grep -n 'devenv_project print-dev-env' "$factum" | head -n1 | cut -d: -f1 || true)
[ -n "$lock_line" ] && [ -n "$prep_line" ] && [ "$lock_line" -lt "$prep_line" ] \
  || fail "$factum must take the heavy lock before host preparation"
! grep -qE '^[^#]*\bflock -w' "$factum" || fail "$factum still takes a second, nested flock"
echo "heavy-lock-test: bare, nested and contended runs and the Factum script ordering pass"
