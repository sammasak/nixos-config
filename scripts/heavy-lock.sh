#!/usr/bin/env bash
# Runs a command under this host's heavy-work lock (modules/core/work-locks.nix, one heavy job per physical host, its
# guests included): it waits for the lock and names the holder. A caller already holding it runs at once: an ancestor
# with the lock file open, as `flock -o /run/work-locks/heavy-work.lock …` is, or one that ran this script; taking it
# again would wait on itself forever. Without the lock file (a host that does not import work-locks.nix) it runs
# unlocked and says so. The command inherits the locked descriptor, so the lock lasts as long as it does.
# Usage: heavy-lock.sh COMMAND [ARG...]   HEAVY_LOCK overrides the path (scripts/test-heavy-lock.py).
set -euo pipefail

lock=${HEAVY_LOCK:-/run/work-locks/heavy-work.lock}
[ "$#" -gt 0 ] || { echo "usage: heavy-lock.sh COMMAND [ARG...]" >&2; exit 2; }
if [ ! -e "$lock" ]; then
  echo "heavy-lock: no $lock on this host, running unlocked" >&2
  exec "$@"
fi
want=$(stat -L -c %d:%i "$lock")

# this process or an ancestor holding the file open: the flock -o wrapper, or a command this script ran (its exec
# keeps the pid and the descriptor), or anything that inherited it
pid=$$
while [ "$pid" -gt 1 ]; do
  for fd in /proc/"$pid"/fd/*; do
    if [ "$(stat -L -c %d:%i "$fd" 2>/dev/null)" = "$want" ]; then
      echo "heavy-lock: $lock is already held by this process or an ancestor (pid $pid), running at once" >&2
      exec "$@"
    fi
  done
  pid=$(awk '{ print $4 }' "/proc/$pid/stat" 2>/dev/null || echo 1)
done

exec {held}<"$lock"
if ! flock -n "$held"; then
  inode=$(stat -L -c %i "$lock")
  # /proc/locks: "1: FLOCK ADVISORY WRITE <pid> <maj:min:inode> 0 EOF"; a waiter's "->" line shifts the fields
  holders=$(awk -v i=":$inode" '$2 == "FLOCK" && substr($6, length($6) - length(i) + 1) == i { print $5 }' /proc/locks | sort -u | tr '\n' ' ')
  holders=${holders% }
  echo "heavy-lock: waiting for $lock, held by pid ${holders:-?}:" >&2
  for p in $holders; do ps -o pid=,etime=,args= -p "$p" >&2 2>/dev/null || true; done
  flock "$held"
  echo "heavy-lock: took $lock" >&2
fi
exec "$@"
