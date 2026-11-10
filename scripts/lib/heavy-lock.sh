# shellcheck shell=bash
# Sourced by heavy test scripts: hold the host's heavy-work lock for the whole script, once.
#
#   heavy_lock_hold "$lock" "$wait_s" "$bash" "$script" "$@"
#
# - **Inherited:** if an ancestor already holds the lock through a descriptor we inherited (a
#   caller ran `flock LOCK bash script`), return and keep going under it. Taking it again on a
#   new descriptor would wait on ourselves forever (the nested-lock deadlock).
# - **Otherwise:** re-exec the script under `flock -w`, so host preparation and the build that
#   follows both run inside one lock acquisition.
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
  exec flock -w "$wait" "$lock" "$@"
}
