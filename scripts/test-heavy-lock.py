"""scripts/heavy-lock.sh, which nixos:qa runs itself under (devenv.nix), on a temporary lock file, without Nix:
without the file it runs unlocked; a free lock is held for the command's whole run; a held one is waited for, with
its holder named; an ancestor already holding it (`flock -o … nixos:qa`, or a nested call) runs at once. Seeded: the
script without its ancestor check deadlocks under `flock -o`, so the check is what prevents it."""
import os
import pathlib
import subprocess
import tempfile
import time

from gate_probe import check, finish

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "heavy-lock.sh"

with tempfile.TemporaryDirectory() as t:
    t = pathlib.Path(t)
    lock = t / "heavy-work.lock"
    env = {**os.environ, "HEAVY_LOCK": str(lock)}

    def run(*cmd, script=SCRIPT, timeout=20, **kw):
        return subprocess.run(["bash", str(script), *cmd], env=env, capture_output=True, text=True, timeout=timeout, **kw)

    r = run("true")
    check(r.returncode == 0 and "running unlocked" in r.stderr, f"no lock file: the command runs unlocked, and says so ({r.stderr.strip()})")

    lock.touch()
    r = run("bash", "-c", f'flock -n "{lock}" true && echo FREE || echo HELD')
    check(r.returncode == 0 and r.stdout.strip() == "HELD", f"a free lock is held while the command runs ({r.stdout.strip()})")
    r = run("bash", "-c", "exit 7")
    check(r.returncode == 7, f"the command's exit status is the script's ({r.returncode})")

    holder = subprocess.Popen(["flock", str(lock), "sleep", "2"])
    time.sleep(0.3)
    start = time.monotonic()
    r = run("true")
    waited = time.monotonic() - start
    holder.wait()
    check(r.returncode == 0 and waited >= 1.2 and "waiting for" in r.stderr and str(holder.pid) in r.stderr,
          f"a held lock is waited for and its holder named ({waited:.1f} s, {r.stderr.strip()!r})")

    r = subprocess.run(["flock", "-o", str(lock), "bash", str(SCRIPT), "true"], env=env, capture_output=True, text=True, timeout=20)
    check(r.returncode == 0 and "by this process or an ancestor" in r.stderr,
          f"under `flock -o` (the old way to gate) it runs at once ({r.stderr.strip()!r})")
    r = run("bash", str(SCRIPT), "true")
    check(r.returncode == 0 and "by a heavy-lock this process descends from" in r.stderr, f"a nested call runs at once ({r.stderr.strip()!r})")

    holder = subprocess.Popen(["flock", str(lock), "sleep", "2"])
    time.sleep(0.3)
    start = time.monotonic()
    r = run("bash", "-c", f'exec 9<"{lock}"; bash "{SCRIPT}" true', script=SCRIPT)
    waited = time.monotonic() - start
    holder.wait()
    check(r.returncode == 0 and waited >= 1.2 and "waiting for" in r.stderr,
          f"seeded: a parent that only has the file open, while another process holds the lock, does not count ({waited:.1f} s)")

    st = os.stat(lock)
    lock_id = f"{os.major(st.st_dev):02x}:{os.minor(st.st_dev):02x}:{st.st_ino}"
    holder = subprocess.Popen(["flock", str(lock), "sleep", "2"])
    time.sleep(0.3)
    start = time.monotonic()
    r = subprocess.run(["bash", "-c", f'exec 9<"{lock}"; HEAVY_LOCK_HELD={lock_id} bash "{SCRIPT}" true'], env=env,
                       capture_output=True, text=True, timeout=20)
    waited = time.monotonic() - start
    holder.wait()
    check(r.returncode == 0 and waited >= 1.2 and "waiting for" in r.stderr and "descends from" not in r.stderr,
          f"seeded: a leaked HEAVY_LOCK_HELD with an unlocked descriptor, while another process holds the lock, waits ({waited:.1f} s)")

    blind = t / "heavy-lock-blind.sh"
    text = SCRIPT.read_text()
    cut = text.index("# this process or an ancestor holding it")
    blind.write_text(text[:cut] + text[text.index('exec {held}<"$lock"'):])
    try:
        r = subprocess.run(["flock", "-o", str(lock), "bash", str(blind), "true"], env=env, capture_output=True,
                           text=True, timeout=4)
        stuck = False
    except subprocess.TimeoutExpired:
        stuck = True
    check(stuck, "seeded: without the ancestor check, `flock -o … heavy-lock.sh` waits on itself")
    # the blind run's own flock is killed with it; the lock is free again
    subprocess.run(["pkill", "-f", str(blind)], check=False)

finish()
