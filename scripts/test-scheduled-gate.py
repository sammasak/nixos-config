"""pkgs/scheduled-gate on a throwaway origin, without Nix: devenv is a stub that records where and how it ran and
writes the platform records a gate would. The full gate runs once per new origin/main head, in a worktree at that
head with mode=scheduled; a red run names its first failed step (a flake check's check included) and the last green
head; a red head runs once more, then waits for a new head; a run with no failed record says unrecorded; a gate killed before it returns records nothing; the textfile
carries exactly the names --list prints."""
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
GATE = ROOT / "pkgs/scheduled-gate/scheduled_gate.py"
failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else f"FAIL (scripts/{__file__.rsplit('/', 1)[-1]}): ") + what)
    failed += not ok


with tempfile.TemporaryDirectory() as t:
    t = pathlib.Path(t)
    bin_dir, origin, work, state = t / "bin", t / "origin.git", t / "work", t / "state"
    bin_dir.mkdir(), state.mkdir()
    calls = t / "calls"
    # the stub's behaviour comes from $t/next: pass, fail-check, fail-bare or kill
    (bin_dir / "devenv").write_text(f"""#!/usr/bin/env bash
set -eu
head=$(git rev-parse HEAD)
echo "$PWD $NIXOS_QA_MODE $head $* clean=$(git status --porcelain | wc -l)" >> {calls}
now=$(date -Iseconds)
case $(cat {t}/next) in
  pass) echo "$now gate-step gate=nixos-qa step=nixos-lint seconds=1 result=pass sha=${{head:0:7}}" >> "$PLATFORM_RECORD_SPOOL" ;;
  fail-check)
    {{ echo "$now gate-step gate=nixos-qa step=nixos-lint seconds=1 result=pass sha=${{head:0:7}}"
      echo "$now gate-step gate=other step=x seconds=1 result=fail sha=${{head:0:7}}"
      echo "$now gate-step gate=nixos-qa step=nixos-flake-check check=checks.x86_64-linux.foo seconds=3 result=fail head=$head drv=/x.drv"
      echo "$now gate-step gate=nixos-qa step=nixos-flake-check seconds=4 result=fail sha=${{head:0:7}}"; }} >> "$PLATFORM_RECORD_SPOOL"
    exit 1 ;;
  fail-bare) exit 1 ;;
  kill) kill -TERM $PPID; sleep 5 ;;
esac
""")
    (bin_dir / "devenv").chmod(0o755)
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(PATH=f"{bin_dir}:{env['PATH']}", HOME=str(t), GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null",
               GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")

    def git(*a, cwd=work):
        return subprocess.run(["git", *a], cwd=cwd, env=env, check=True, capture_output=True, text=True).stdout.strip()

    def commit(text):
        (work / "flake.nix").write_text(text)
        git("commit", "-qam", text)
        git("push", "-q", "origin", "HEAD:main")
        return git("rev-parse", "HEAD")

    git("init", "-q", "--bare", "-b", "main", str(origin), cwd=t)
    git("init", "-q", "-b", "main", str(work), cwd=t)
    git("remote", "add", "origin", str(origin))
    (work / "flake.nix").write_text("0\n")
    git("add", "-A")
    git("commit", "-qm", "0")
    git("push", "-q", "origin", "main")
    prom = state / "metrics.prom"

    def run(behaviour):
        (t / "next").write_text(behaviour)
        calls.write_text("")
        r = subprocess.run([sys.executable, "-I", str(GATE), "--repo", str(origin), "--state", str(state),
                            "--metrics", str(prom)], env=env, capture_output=True, text=True, timeout=60)
        return r, calls.read_text().splitlines()

    def metrics():
        out = {}
        for line in prom.read_text().splitlines():
            if not line.startswith("#"):
                name, value = line.rsplit(" ", 1)
                out[name] = float(value)
        return out

    def red():
        return [k for k in metrics() if k.startswith("homelab_scheduled_gate_red")]

    h1 = git("rev-parse", "HEAD")
    r, ran = run("pass")
    check(r.returncode == 0 and len(ran) == 1 and ran[0] == f"{state}/tree scheduled {h1} tasks run nixos:qa clean=0",
          f"A first run: nixos:qa once, mode=scheduled, in a clean worktree at origin/main ({ran}, {r.stderr.strip()})")
    m = metrics()
    check(abs(m["homelab_scheduled_gate_checked_timestamp_seconds"] - time.time()) < 30, f"A the check time to the second ({m})")
    check(m["homelab_scheduled_gate_main_behind"] == 0 and m["homelab_scheduled_gate_finished_timestamp_seconds"] > 0
          and not red(), f"A a green run: not behind, finished, no red series ({m})")
    check(not (state / "tree").exists() and git("worktree", "list", cwd=state / "repo").count("\n") == 0,
          "A the worktree is removed after the run")
    r, ran = run("pass")
    check(r.returncode == 0 and ran == [], f"B main has not moved: nothing runs ({ran})")
    check(json.loads((state / "state.json").read_text())["green"] == h1, "B the state keeps the green head")

    h2 = commit("2\n")
    r, ran = run("fail-check")
    reds = red()
    want = f'homelab_scheduled_gate_red{{head="{h2[:12]}",step="nixos-flake-check (checks.x86_64-linux.foo)",green="{h1[:12]}"}}'
    check(r.returncode == 0 and len(ran) == 1 and reds == [want],
          f"C a red run names the first failed nixos-qa step, its check, and the last green head; the unit passes ({reds})")
    check(metrics()["homelab_scheduled_gate_main_behind"] == 0, "C a red run on main's head is not behind")
    r, ran = run("fail-check")
    check(len(ran) == 1 and h2 in ran[0] and red() == [want], f"D a red head runs once more, and red again stays red ({ran})")
    r, ran = run("pass")
    check(ran == [] and red() == [want], "D after its retry the same head is not run again and stays red")

    h3 = commit("3\n")
    r, ran = run("fail-bare")
    want3 = f'homelab_scheduled_gate_red{{head="{h3[:12]}",step="unrecorded",green="{h1[:12]}"}}'
    check(red() == [want3], f"E a red run with no failed record of its own head says unrecorded ({red()})")

    h4 = commit("4\n")
    (state / "tree").mkdir()
    (state / "tree" / "stale").write_text("x\n")
    r, ran = run("kill")
    s = json.loads((state / "state.json").read_text())
    check(r.returncode != 0 and s["head"] == h3 and metrics()["homelab_scheduled_gate_main_behind"] == 1,
          f"F a gate killed mid-run records nothing: the last finished head stays, main reads behind ({s['head'][:12]})")
    r, ran = run("pass")
    check(len(ran) == 1 and h4 in ran[0] and red() == [], f"G the next run gates that head, green clears red ({ran})")
    m = metrics()
    check(m["homelab_scheduled_gate_green_timestamp_seconds"] == m["homelab_scheduled_gate_finished_timestamp_seconds"] > 0,
          f"G the green time is the passing run's finish ({m})")
    check(json.loads((state / "state.json").read_text())["green"] == h4, "G the green head moves")
    h5 = commit("4b\n")
    run("fail-check")
    r, ran = run("pass")
    check(len(ran) == 1 and h5 in ran[0] and red() == [], f"G2 a red head that passes on its retry clears red ({ran})")

    listed = subprocess.run([sys.executable, "-I", str(GATE), "--list"], capture_output=True, text=True,
                            check=True).stdout.split()
    typed = re.findall(r"^# TYPE (\S+) gauge$", prom.read_text(), re.M)
    check(listed == typed and len(listed) == 7, f"--list names exactly the series the textfile types ({listed})")
    commit("5\n")
    run("fail-check")
    exposed = {re.split(r"[{ ]", line)[0] for line in prom.read_text().splitlines() if not line.startswith("#")}
    check(exposed == set(listed), f"a red textfile has a sample of every listed series ({sorted(exposed)})")

print(f"{failed} failed" if failed else "all passed")
sys.exit(1 if failed else 0)
