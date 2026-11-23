#!/usr/bin/env python3
"""Runs a command under this host's heavy-work lock (modules/core/work-locks.nix, one heavy job per physical host, its
guests included): it waits for the lock and names the holder. A caller already holding it runs at once: this process
or an ancestor that /proc/locks names as the holder, as `flock -o /run/work-locks/heavy-work.lock …` is, or one that
ran this program; taking it again would wait on itself forever. A launcher holding it across a process it does not
parent (systemd-run) sets NIXOS_QA_LOCKED=1 for nixos:qa instead. Without the lock file (a host that does not import
work-locks.nix) it runs unlocked and says so. The command inherits the locked descriptor, so the lock lasts as long as
it and anything it leaves running. HEAVY_LOCK_WAIT_SECONDS tells the command how long it waited for the lock: 0 when
it was free or absent; left as inherited when an ancestor holds it (a nested call keeps the outer wait, a `flock -o`
launcher leaves it unset: that wait was not measured here).
Usage: heavy-lock COMMAND [ARG...]   HEAVY_LOCK overrides the path (scripts/test-heavy-lock.py)."""

from __future__ import annotations

import fcntl
import os
import subprocess
import sys
import time

PS = "ps"
WAIT = "HEAVY_LOCK_WAIT_SECONDS"


def say(text: str) -> None:
    print(f"heavy-lock: {text}", file=sys.stderr, flush=True)


def run(cmd: list[str]) -> None:
    try:
        os.execvp(cmd[0], cmd)
    except FileNotFoundError:
        say(f"{cmd[0]}: command not found")
        sys.exit(127)
    except PermissionError:
        say(f"{cmd[0]}: permission denied")
        sys.exit(126)


def lock_id(st: os.stat_result) -> str:
    """The lock's id as /proc/locks prints it: major:minor in hex, then the inode."""
    return f"{os.major(st.st_dev):02x}:{os.minor(st.st_dev):02x}:{st.st_ino}"


def holders(lid: str) -> list[str]:
    """Pids holding a flock on the file. A waiter's line ("1: -> FLOCK …") shifts the fields, so it is not matched."""
    with open("/proc/locks") as f:
        return sorted({p[4] for p in (line.split() for line in f) if len(p) > 5 and p[1] == "FLOCK" and p[5] == lid})


def descends_from_holder(st: os.stat_result) -> bool:
    """A descriptor a heavy-lock locked, inherited (HEAVY_LOCK_HELD marks it): /proc/locks names the process that took
    it, which has exec'd into the command, so the holder cannot be found by pid. A non-blocking flock on it proves
    it: the lock it already holds is taken again at once, while an unlocked descriptor (a leaked marker) fails
    whenever someone else holds the lock."""
    for name in os.listdir("/proc/self/fd"):
        try:
            fst = os.fstat(int(name))
            if (fst.st_dev, fst.st_ino) == (st.st_dev, st.st_ino):
                fcntl.flock(int(name), fcntl.LOCK_EX | fcntl.LOCK_NB)
                return True
        except OSError:
            continue
    return False


def ancestor(held_by: list[str]) -> int | None:
    """This process or an ancestor holding it: the flock -o wrapper, or a command this program ran (exec keeps the
    pid). The parent pid follows the command name, which may hold spaces or parentheses."""
    pid = os.getpid()
    while pid > 1:
        if str(pid) in held_by:
            return pid
        try:
            with open(f"/proc/{pid}/stat") as f:
                pid = int(f.read().rsplit(") ", 1)[1].split()[1])
        except (OSError, IndexError, ValueError):
            return None
    return None


def main(argv: list[str]) -> None:
    if not argv:
        print("usage: heavy-lock COMMAND [ARG...]", file=sys.stderr)
        sys.exit(2)
    lock = os.environ.get("HEAVY_LOCK", "/run/work-locks/heavy-work.lock")
    if not os.path.exists(lock):
        say(f"no {lock} on this host, running unlocked")
        os.environ[WAIT] = "0"
        run(argv)
    st = os.stat(lock)
    lid = lock_id(st)
    if os.environ.get("HEAVY_LOCK_HELD") == lid and descends_from_holder(st):
        say(f"{lock} is already held, by a heavy-lock this process descends from; running at once")
        run(argv)
    pid = ancestor(holders(lid))
    if pid is not None:
        say(f"{lock} is already held by this process or an ancestor (pid {pid}), running at once")
        run(argv)
    # read-only: a guest binds /run/work-locks read-only, and flock needs no write access
    fd = os.open(lock, os.O_RDONLY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.environ[WAIT] = "0"
    except BlockingIOError:
        waiting = holders(lid)
        # a holder in another PID namespace (the host, seen from a guest) shows as pid 0
        say(f"waiting for {lock}, held by pid {' '.join(waiting) or '?'}:")
        for p in waiting:
            subprocess.run([PS, "-o", "pid=,etime=,args=", "-p", p], stdout=sys.stderr, stderr=subprocess.DEVNULL,
                           check=False)
        start = time.monotonic()
        fcntl.flock(fd, fcntl.LOCK_EX)
        os.environ[WAIT] = f"{time.monotonic() - start:.1f}"
        say(f"took {lock}")
    os.set_inheritable(fd, True)
    os.environ["HEAVY_LOCK_HELD"] = lid
    run(argv)


if __name__ == "__main__":
    main(sys.argv[1:])
