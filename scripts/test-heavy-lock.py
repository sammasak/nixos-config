"""The heavy-work lock wrapper (pkgs/heavy-lock), which nixos:qa runs itself under (devenv.nix), on a temporary lock
file: without the file it runs unlocked; a free lock is held for the command's whole run; a held one is waited for, with
its holder named; an ancestor already holding it (`flock -o … nixos:qa`, or a nested call) runs at once. The command is
told its wait in HEAVY_LOCK_WAIT_SECONDS: 0 on a free or absent lock, the measured wait on a held one, the outer wait in
a nested call, unset under a `flock -o` launcher (not measured here). Seeded: the wrapper without its ancestor check
deadlocks under `flock -o`, so the check is what prevents it; one that does not time its wait reports a contended lock
as 0. Run as `test-heavy-lock.py [the packaged heavy-lock]`, else the source."""
import os
import pathlib
import shlex
import subprocess
import sys
import tempfile
import time

from gate_probe import check, finish

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "pkgs/heavy-lock/heavy_lock.py"
PROGRAM = sys.argv[1:] or [sys.executable, str(SOURCE)]
WAIT = 'echo "${HEAVY_LOCK_WAIT_SECONDS-unset}"'

with tempfile.TemporaryDirectory() as t:
    t = pathlib.Path(t)
    lock = t / "heavy-work.lock"
    env = {k: v for k, v in os.environ.items() if not k.startswith("HEAVY_LOCK")} | {"HEAVY_LOCK": str(lock)}

    def run(*cmd, program=PROGRAM, timeout=20):
        return subprocess.run([*program, *cmd], env=env, capture_output=True, text=True, timeout=timeout, check=False)

    def contended(*cmd, program=PROGRAM, shell=None):
        holder = subprocess.Popen(["flock", str(lock), "sleep", "2"])
        time.sleep(0.3)
        start = time.monotonic()
        if shell is None:
            r = run(*cmd, program=program)
        else:
            r = subprocess.run(["bash", "-c", shell], env=env, capture_output=True, text=True, timeout=20, check=False)
        waited = time.monotonic() - start
        holder.wait()
        return r, waited

    r = run("bash", "-c", WAIT)
    check(r.returncode == 0 and "running unlocked" in r.stderr and r.stdout.strip() == "0",
          f"no lock file: the command runs unlocked, says so, and waited 0 ({r.stderr.strip()}, {r.stdout.strip()})")

    lock.touch()
    r = run("bash", "-c", f'flock -n "{lock}" true && echo FREE || echo HELD')
    check(r.returncode == 0 and r.stdout.strip() == "HELD",
          f"a free lock is held while the command runs ({r.stdout.strip()})")
    r = run("bash", "-c", WAIT)
    check(r.stdout.strip() == "0", f"a free lock: the wait is 0 ({r.stdout.strip()})")
    r = run("bash", "-c", "exit 7")
    check(r.returncode == 7, f"the command's exit status is the wrapper's ({r.returncode})")

    r, waited = contended("bash", "-c", WAIT)
    holder_named = "waiting for" in r.stderr and "held by pid" in r.stderr
    check(r.returncode == 0 and waited >= 1.2 and holder_named and float(r.stdout.strip() or 0) >= 1.2,
          f"a held lock is waited for, its holder named, and the wait told to the command ({waited:.1f} s, "
          f"{r.stdout.strip()}, {r.stderr.strip()!r})")

    r = subprocess.run(["flock", "-o", str(lock), *PROGRAM, "bash", "-c", WAIT], env=env, capture_output=True,
                       text=True, timeout=20, check=False)
    check(r.returncode == 0 and "by this process or an ancestor" in r.stderr and r.stdout.strip() == "unset",
          f"under `flock -o` (the old way to gate) it runs at once, the wait unmeasured ({r.stderr.strip()!r})")
    r = run(*PROGRAM, "true")
    check(r.returncode == 0 and "by a heavy-lock this process descends from" in r.stderr,
          f"a nested call runs at once ({r.stderr.strip()!r})")
    r, waited = contended(*PROGRAM, "bash", "-c", WAIT)
    check(r.returncode == 0 and "descends from" in r.stderr and float(r.stdout.strip() or 0) >= 1.2,
          f"a nested call keeps the outer call's wait ({r.stdout.strip()})")

    r, waited = contended(shell=f'exec 9<"{lock}"; exec {shlex.join(PROGRAM)} true')
    check(r.returncode == 0 and waited >= 1.2 and "waiting for" in r.stderr,
          f"seeded: a parent that only has the file open, while another process holds the lock, does not count "
          f"({waited:.1f} s)")

    st = os.stat(lock)
    lock_id = f"{os.major(st.st_dev):02x}:{os.minor(st.st_dev):02x}:{st.st_ino}"
    r, waited = contended(shell=f'exec 9<"{lock}"; HEAVY_LOCK_HELD={lock_id} exec {shlex.join(PROGRAM)} true')
    check(r.returncode == 0 and waited >= 1.2 and "waiting for" in r.stderr and "descends from" not in r.stderr,
          f"seeded: a leaked HEAVY_LOCK_HELD with an unlocked descriptor, while another process holds the lock, waits "
          f"({waited:.1f} s)")

    # the seeds are copies of the wrapper's own text (the package's, when one is tested), run by this python
    text = pathlib.Path(PROGRAM[-1]).read_text()

    def copy(name, old, new):
        assert text.count(old) == 1, f"seed {name}: {old!r} not found once in the wrapper"
        path = t / f"heavy-lock-{name}.py"
        path.write_text(text.replace(old, new))
        return [sys.executable, str(path)]

    blind = copy("blind", "    pid = ancestor(holders(lid))\n", "    pid = None\n")
    try:
        subprocess.run(["flock", "-o", str(lock), *blind, "true"], env=env, capture_output=True, text=True, timeout=4,
                       check=False)
        stuck = False
    except subprocess.TimeoutExpired:
        stuck = True
    check(stuck, "seeded: without the ancestor check, `flock -o … heavy-lock` waits on itself")
    # the blind run's own flock is killed with it; the lock is free again
    subprocess.run(["pkill", "-f", blind[-1]], check=False)

    untimed = copy("untimed", 'os.environ[WAIT] = f"{time.monotonic() - start:.1f}"', 'os.environ[WAIT] = "0"')
    r, waited = contended("bash", "-c", WAIT, program=untimed)
    check(float(r.stdout.strip() or 0) < 1.2 <= waited,
          f"seeded: a wrapper that does not time its wait reports a contended lock as {r.stdout.strip()}, which the "
          "check above refuses")

finish()
