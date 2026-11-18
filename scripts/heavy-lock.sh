#!/usr/bin/env bash
# Runs a command under this host's heavy-work lock (modules/core/work-locks.nix, one heavy job per physical host, its
# guests included): it waits for the lock and names the holder. A caller already holding it runs at once: this process
# or an ancestor that /proc/locks names as the holder, as `flock -o /run/work-locks/heavy-work.lock …` is, or one that
# ran this script; taking it again would wait on itself forever. A launcher holding it across a process it does not
# parent (systemd-run) sets NIXOS_QA_LOCKED=1 for nixos:qa instead. Without the lock file (a host that does not import
# work-locks.nix) it runs unlocked and says so. The command inherits the locked descriptor, so the lock lasts as long
# as it and anything it leaves running.
# Usage: heavy-lock.sh COMMAND [ARG...]   HEAVY_LOCK overrides the path (scripts/test-heavy-lock.py).
set -euo pipefail

lock=${HEAVY_LOCK:-/run/work-locks/heavy-work.lock}
[ "$#" -gt 0 ] || { echo "usage: heavy-lock.sh COMMAND [ARG...]" >&2; exit 2; }
if [ ! -e "$lock" ]; then
  echo "heavy-lock: no $lock on this host, running unlocked" >&2
  exec "$@"
fi
# /proc/locks: "1: FLOCK ADVISORY WRITE <pid> <maj:min:inode> 0 EOF", the device in hex; a waiter's "->" line shifts
# the fields
dev=$(stat -L -c %d "$lock")
id=$(printf '%02x:%02x:%s' $(((dev >> 8) & 0xfff)) $(((dev & 0xff) | ((dev >> 12) & 0xfff00))) "$(stat -L -c %i "$lock")")
holders() { awk -v id="$id" '$2 == "FLOCK" && $6 == id { print $5 }' /proc/locks | sort -u; }
held_by=$(holders)

# a descriptor this script locked, inherited (HEAVY_LOCK_HELD marks it): /proc/locks names the flock command that took
# it, which has exited, so the holder cannot be found by pid. flock -n on it proves it: the lock it already holds is
# taken again at once, while an unlocked descriptor (a leaked marker) fails whenever someone else holds the lock.
if [ "${HEAVY_LOCK_HELD:-}" = "$id" ]; then
  for fd in "/proc/$$/fd"/*; do
    if [ "$(stat -L -c %d:%i "$fd" 2>/dev/null)" = "$dev:$(stat -L -c %i "$lock")" ] && flock -n "${fd##*/}"; then
      echo "heavy-lock: $lock is already held, by a heavy-lock this process descends from; running at once" >&2
      exec "$@"
    fi
  done
fi

# this process or an ancestor holding it: the flock -o wrapper, or a command this script ran (its exec keeps the pid)
pid=$$
while [ "$pid" -gt 1 ]; do
  if grep -qx "$pid" <<<"$held_by"; then
    echo "heavy-lock: $lock is already held by this process or an ancestor (pid $pid), running at once" >&2
    exec "$@"
  fi
  # the parent pid follows the command name, which may hold spaces or parentheses
  stat=$(cat "/proc/$pid/stat" 2>/dev/null) || break
  stat=${stat##*) }
  read -r _ pid _ <<<"$stat"
done

exec {held}<"$lock"
if ! flock -n "$held"; then
  waiting=$(holders | tr '\n' ' ')
  waiting=${waiting% }
  # a holder in another PID namespace (the host, seen from a guest) shows as pid 0
  echo "heavy-lock: waiting for $lock, held by pid ${waiting:-?}:" >&2
  for p in $waiting; do ps -o pid=,etime=,args= -p "$p" >&2 2>/dev/null || true; done
  flock "$held"
  echo "heavy-lock: took $lock" >&2
fi
export HEAVY_LOCK_HELD=$id
exec "$@"
