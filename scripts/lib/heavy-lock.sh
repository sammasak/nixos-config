# shellcheck shell=bash
# Sourced by heavy test scripts: hold the host's heavy-work lock for the whole script, once.
#
#   heavy_lock_hold "$lock" "$wait_s" "$bash" "$script" "$@"
#
# - **Inherited:** if an ancestor already holds the lock through a descriptor we inherited (a
#   caller ran `flock LOCK bash script`), return and keep going under it. Taking it again on a
#   new descriptor would wait on ourselves forever (the nested-lock deadlock).
# - **Otherwise:** re-run the script under `flock -w`, so host preparation and the build that
#   follows both run inside one lock acquisition. A wait that expires exits 75 with a message.
#
# `flock` must be on PATH.
heavy_lock_hold() {
  local lock=$1 wait=$2 fd target
  shift 2
  target=$(readlink -f -- "$lock")
  for fd in "/proc/$$/fd"/*; do
    [ "$(readlink -- "$fd" 2>/dev/null)" = "$target" ] || continue
    # The same open file description re-locks without waiting only if it is the holder.
    if flock -n "${fd##*/}"; then
      return 0
    fi
  done
  # Not `exec`: a wait that times out must say so instead of exiting 1 without a word. The
  # script itself runs as flock's child, holding the lock, and finds it inherited above.
  local rc=0
  flock -w "$wait" -E 75 "$lock" "$@" || rc=$?
  if [ "$rc" = 75 ]; then
    echo "heavy-lock: timed out after ${wait}s waiting for $lock" >&2
  fi
  exit "$rc"
}
