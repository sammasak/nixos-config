#!/usr/bin/env python3
"""`just deploy HOST` and `just dry-activate HOST` against stub git, nix, ssh, sudo, systemd-run, systemctl and readlink
on PATH and stub system-checks.sh and platform_record.py; ssh runs its command here, stdin included. deploy feeds the
real scripts/post-deploy-check.sh to the target, so a unit in a restart loop, which is-system-running reads as running,
fails it with result=check-failed. deploy-rs's --dry-activate exits 0 whatever the dry activation did, so dry-activate
reruns switch-to-configuration dry-activate over ssh and exits non-zero, with its output, when that or the closure diff
fails, and 0 when both pass. A deploy of a host whose lock (in XDG_RUNTIME_DIR, here a temporary directory) is held is
refused at once with result=locked; one of another host waits for the shared lock a running deploy holds, bounded by
DEPLOY_LOCK_WAIT, recording result=waited or result=lock-timeout. Every private (sammasak) input of flake.lock is git over ssh, so a deploy as the
user fetches a new pin with that user's key; a github: input would need the root-only nix access token."""
import fcntl
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import time

from gate_probe import check, finish

ROOT = pathlib.Path(__file__).resolve().parent.parent


STUBS = {
    "bin/systemd-run": 'echo "systemd-run $*" >> "$LOG"; while [ "${1:-}" != nix ]; do shift; done; exec "$@"',
    # `nix run … deploy-rs -- …` is deploy-rs, which prints success over a failed dry activation
    "bin/nix": """echo "nix $*" >> "$LOG"
case "$*" in
  run*--dry-activate*) echo "Completed dry-activate!" ;;
  run*) flock -n "$XDG_RUNTIME_DIR/deploy.lock" true && echo "deploy-rs shared=free" >> "$LOG" || echo "deploy-rs shared=held" >> "$LOG"
        echo "Success activating, done!"; exit "${DEPLOY_RC:-0}" ;;
  *toplevel*) printf '%s' "$FIX/top" ;;
  *hostname*) printf target ;;
  *diff-closures*) exit "${DIFF_RC:-0}" ;;
esac""",
    # the target has exec-pool-drain only as the pool fixture, whatever this host's PATH holds
    "bin/ssh": """echo "ssh $*" >> "$LOG"; shift 3
case "$*" in "bash -s"*) flock -n "$XDG_RUNTIME_DIR/deploy.lock" true && echo "post-deploy shared=free" >> "$LOG" \
  || echo "post-deploy shared=held" >> "$LOG" ;; esac
[ "$*" != "command -v exec-pool-drain" ] || [ -x "$FIX/bin/exec-pool-drain" ] || exit 1
exec bash -c "$*"
""",
    "bin/sudo": 'echo "sudo $*" >> "$LOG"; exec "$@"',
    # a clean tree on origin/main
    "bin/git": 'case $1 in rev-parse) echo abc123 ;; esac',
    # the target's systemd: running, with waiting.service in auto-restart when LOOP is set
    "bin/systemctl": """case "$*" in
  is-system-running*) echo running ;;
  list-units*) printf 'sshd.service loaded active running SSH\\nwaiting.service loaded activating auto-restart w\\n' ;;
  show*) printf 'Id=sshd.service\\nActiveState=active\\nSubState=running\\nNRestarts=0\\nConditionResult=yes\\nConditionTimestampMonotonic=1\\nFragmentPath=/etc/systemd/system/sshd.service\\nDropInPaths=\\n\\n'
         sub=running; [ -z "${LOOP:-}" ] || sub=auto-restart
         # SHADOW: a runtime drop-in (`systemctl edit --runtime`), outside the store; generator and transient units are
         # systemd's own
         printf 'Id=waiting.service\\nActiveState=activating\\nSubState=%s\\nNRestarts=0\\nConditionResult=yes\\nConditionTimestampMonotonic=1\\nFragmentPath=/etc/systemd/system/waiting.service\\nDropInPaths=/run/systemd/generator/waiting.service.d/x.conf%s\\n\\n' "$sub" "${SHADOW:+ /run/systemd/system/waiting.service.d/override.conf}"
         printf 'Id=run-u1.scope\\nActiveState=active\\nSubState=running\\nNRestarts=0\\nConditionResult=yes\\nConditionTimestampMonotonic=1\\nFragmentPath=/run/systemd/transient/run-u1.scope\\nDropInPaths=\\n' ;;
esac""",
    # the system profile's generation is the running one
    "bin/readlink": 'case "$*" in *override.conf) echo "$2" ;; -f*) echo /nix/store/sys/init ;; *) echo /nix/store/sys ;; esac',
    "scripts/system-checks.sh": 'echo "system-checks toplevel=${SYSTEM_CHECKS_TOPLEVEL:-0} $*" >> "$LOG"',
    "pkgs/platform-record/platform_record.py": 'echo "record $*" >> "$LOG"',
    "top/bin/switch-to-configuration": 'echo "would restart: x.service"; [ "$1" = dry-activate ]; exit "${DRY_RC:-0}"',
}


def run(recipe, shadow="", check_script=None, host="acer-swift", runtime=None, justfile=ROOT / "Justfile", pool=False,
        during=None, **env):
    """shadow: the activation's report on the target (None: there is none); check_script: the post-deploy check's text;
    runtime: XDG_RUNTIME_DIR, where the deploy locks are (default: a fresh one); pool: the target has exec-pool-drain,
    whose `wait` exits DRAIN_WAIT_RC; during: called with the stub log's path while the recipe runs."""
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        for rel, body in STUBS.items():
            (tmp / rel).parent.mkdir(parents=True, exist_ok=True)
            (tmp / rel).write_text("#!/usr/bin/env bash\n" + body + "\n")
            (tmp / rel).chmod(0o755)
        (tmp / "scripts/post-deploy-check.sh").write_text(check_script or (ROOT / "scripts/post-deploy-check.sh").read_text())
        if shadow is not None:
            (tmp / "shadowed-user-units").write_text(shadow)
        if pool:
            drain = tmp / "bin/exec-pool-drain"
            drain.write_text('#!/usr/bin/env bash\necho "drain $*" >> "$LOG"\n[ "$1" != wait ] || exit "${DRAIN_WAIT_RC:-0}"\n')
            drain.chmod(0o755)
        (tmp / "log").touch()
        proc = subprocess.Popen([shutil.which("just"), "--justfile", str(justfile), "--working-directory", str(tmp),
                                 recipe, host], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                env=dict(os.environ, PATH=f"{tmp / 'bin'}:{env.pop('PATH', os.environ['PATH'])}",
                                         FIX=str(tmp), XDG_RUNTIME_DIR=str(runtime or tmp), LOG=str(tmp / "log"),
                                         SHADOWED_USER_UNITS=str(tmp / "shadowed-user-units"), **env))
        if during:
            during(tmp / "log")
        out = proc.communicate()[0]
        return proc.returncode, out, (tmp / "log").read_text()


rc, out, log = run("deploy")
check("deploy-rs shared=held" in log and "post-deploy shared=free" in log,
      "deploy: the shared lock is held while deploy-rs runs and released before the post-deploy check")
check(rc == 0 and "result=ok" in log and "post-deploy: unit in a restart loop" not in out,
      f"deploy: a healthy target passes the post-deploy check and records ok (rc {rc}: {out.strip()[-300:]})")
rc, out, log = run("deploy", LOOP="1")
check(rc == 1 and "unit in a restart loop: waiting.service (activating/auto-restart" in out and "result=check-failed" in log,
      f"deploy: a unit in auto-restart on a running system fails the check, result=check-failed (rc {rc}: {out.strip()[-300:]})")

rc, out, log = run("deploy", SHADOW="1")
check(rc == 0 and "result=ok" in log and "warning: unit files not from the deployed generation (not a failure): "
      "waiting.service (/run/systemd/system/waiting.service.d/override.conf)" in out and "generator" not in out.split("warning:")[-1],
      f"deploy: a runtime drop-in outside the store is a warning, not a failure (rc {rc}: {out.strip()[-300:]})")
check("not from the deployed generation" not in run("deploy")[1],
      "deploy: store units, generator drop-ins and transient units raise no warning")

check("shadowed" not in run("deploy")[1], "deploy: an empty shadow report (the activation found nothing) says nothing")
SHADOWED = "/home/lukas/.config/systemd/user/ollama-portforward.service shadows the NixOS user unit ollama-portforward.service"
rc, out, log = run("deploy", shadow=SHADOWED + " (/etc/systemd/user): …\n")
check(rc == 1 and "result=check-failed" in log and f"user unit shadowed at the last activation: {SHADOWED}" in out
      and "a home shadowing a NixOS user unit" in out,
      f"deploy: a line in the activation's shadow report fails the check, result=check-failed (rc {rc}: {out.strip()[-300:]})")
rc, out, log = run("deploy", shadow=None)
check(rc == 0 and "result=ok" in log and "shadowed user units are not checked (not a failure)" in out,
      f"deploy: no shadow report (an older activation) is a warning, not a failure (rc {rc}: {out.strip()[-200:]})")
old = subprocess.run(["git", "-C", str(ROOT), "show", "origin/main:scripts/post-deploy-check.sh"], capture_output=True, text=True)
if old.returncode == 0 and "shadowed-user-units" not in old.stdout:
    rc, out, log = run("deploy", shadow=SHADOWED + "\n", check_script=old.stdout)
    check(rc == 0 and "result=ok" in log,
          f"seeded: main's post-deploy check passes a host whose activation found a shadowed unit, so the check above is new (rc {rc})")

check("exec-pool-drain on" not in run("deploy")[2], "deploy: a host without exec-pool-drain is deployed without a drain")
with tempfile.TemporaryDirectory() as own:
    (pathlib.Path(own) / "exec-pool-drain").write_text("#!/usr/bin/env bash\nexit 1\n")
    (pathlib.Path(own) / "exec-pool-drain").chmod(0o755)
    check("exec-pool-drain on" not in run("deploy", PATH=f"{os.environ['PATH']}:{own}")[2],
          "seeded: a drain on the test host's own PATH does not make the target a pool host")
rc, out, log = run("deploy", pool=True)
steps = [l.split()[0] + " " + l.split()[1] for l in log.splitlines() if l.startswith(("system-checks", "drain", "nix run"))]
check(rc == 0 and "result=ok" in log
      and steps == ["system-checks toplevel=1", "drain on", "drain wait", "nix run", "drain off"]
      and "sudo exec-pool-drain off" in log,
      f"deploy: a pool host's toplevel is built, then it is drained and waited for before deploy-rs, and its drain "
      f"cleared after (rc {rc}: {steps})")
rc, out, log = run("deploy", pool=True, DEPLOY_RC="1")
check(rc == 1 and "result=deploy-failed" in log and log.splitlines().count("drain off") == 1,
      f"deploy: a failed or rolled back deploy clears the drain too, once (rc {rc}: {out.strip()[-200:]})")
rc, out, log = run("deploy", pool=True, DRAIN_WAIT_RC="1")
check(rc == 0 and "still runs a pool attempt after the drain's wait; deploying anyway" in out and "nix run" in log
      and "drain off" in log,
      f"deploy: a pool attempt outlasting the drain's wait is said, and the deploy goes on (rc {rc}: {out.strip()[-200:]})")

with tempfile.TemporaryDirectory() as runtime:
    lock = pathlib.Path(runtime) / "deploy-acer-swift.lock"
    with open(lock, "w") as held:
        fcntl.flock(held, fcntl.LOCK_EX)
        held.write("pid 4242, def456, since 10:00:00\n")
        held.flush()
        t0 = time.monotonic()
        rc, out, log = run("deploy", runtime=runtime)
        took = time.monotonic() - t0
        check(rc != 0 and took < 10 and "result=locked" in log and "nix run" not in log and "system-checks" not in log
              and "acer-swift is being deployed already (pid 4242, def456, since 10:00:00)" in out,
              f"deploy: a deploy of a host being deployed is refused at once ({took:.1f}s), naming the holder, and "
              f"records result=locked (rc {rc}: {out.strip()[-200:]})")
        rc, out, log = run("deploy", host="black-pi", runtime=runtime)
        check(rc == 0 and "result=ok" in log and ".#black-pi" in log,
              f"deploy: another host deploys while acer-swift is locked (rc {rc}: {out.strip()[-200:]})")
        # seed: the recipe without its lock lines deploys the locked host; the links keep justfile_directory()'s files
        seed = pathlib.Path(runtime) / "seed"
        seed.mkdir()
        for p in ROOT.iterdir():
            if p.name not in ("Justfile", ".git"):
                (seed / p.name).symlink_to(p)
        (seed / "Justfile").write_text("".join(l for l in (ROOT / "Justfile").read_text().splitlines(True)
                                               if "$lock" not in l))
        rc, out, log = run("deploy", runtime=runtime, justfile=seed / "Justfile")
        check(rc == 0 and "result=ok" in log,
              f"seeded: without the lock lines a deploy of the locked host runs, so the refusal above is the lock's "
              f"(rc {rc}: {out.strip()[-200:]})")
    rc, out, log = run("deploy", runtime=runtime)
    check(rc == 0 and "result=ok" in log and lock.read_text().startswith("pid "),
          f"deploy: once the holder exits, the host deploys and records itself as the holder (rc {rc}: {out.strip()[-200:]})")

with tempfile.TemporaryDirectory() as runtime:
    shared = pathlib.Path(runtime) / "deploy.lock"
    with open(shared, "w") as held:
        fcntl.flock(held, fcntl.LOCK_EX)
        held.write("msi-ms7758, pid 4242, def456, since 10:30:00\n")
        held.flush()
        seen = {}

        def release(log):
            # a blocked flock waiter shows in /proc/locks as "-> ... <inode>"
            inode = f":{os.stat(shared).st_ino} "
            for _ in range(300):
                if any(l.split()[1] == "->" and inode in l for l in pathlib.Path("/proc/locks").read_text().splitlines()):
                    break
                time.sleep(0.1)
            time.sleep(1.1)
            seen["before"] = log.read_text()
            fcntl.flock(held, fcntl.LOCK_UN)

        rc, out, log = run("deploy", runtime=runtime, during=release, DEPLOY_LOCK_WAIT="60")
        check(rc == 0 and "system-checks" not in seen["before"] and "nix run" not in seen["before"]
              and "waiting up to 60s for the deploy of msi-ms7758, pid 4242, def456, since 10:30:00" in out
              and int(log.split("result=waited seconds=")[-1].split()[0] if "result=waited" in log else 0) >= 1
              and "result=ok" in log
              and log.index("result=waited") < log.index("system-checks") < log.index("result=ok")
              and shared.read_text().startswith("acer-swift, pid "),
              f"deploy: with another host's deploy holding the shared lock, it waits, naming the holder, then runs once "
              f"it is freed and records result=waited with the wait (rc {rc}: {out.strip()[-300:]})")
        fcntl.flock(held, fcntl.LOCK_EX)
        held.seek(0)
        held.truncate()
        held.write("msi-ms7758, pid 4242, def456, since 10:30:00\n")
        held.flush()
        with open(pathlib.Path(runtime) / "deploy-acer-swift.lock", "w") as own:
            fcntl.flock(own, fcntl.LOCK_EX)
            t0 = time.monotonic()
            rc, out, log = run("deploy", runtime=runtime, DEPLOY_LOCK_WAIT="60")
            took = time.monotonic() - t0
            check(rc != 0 and took < 10 and "result=locked" in log and "waiting up to 60s for the deploy of" not in out,
                  f"deploy: a host being deployed is refused at once even while the shared lock is held ({took:.1f}s, "
                  f"rc {rc})")
        rc, out, log = run("deploy", runtime=runtime, DEPLOY_LOCK_WAIT="soon")
        check(rc == 2 and "DEPLOY_LOCK_WAIT" in out and "result=" not in log,
              f"deploy: a DEPLOY_LOCK_WAIT that is not whole seconds is refused, not taken for a timeout (rc {rc})")
        t0 = time.monotonic()
        rc, out, log = run("deploy", runtime=runtime, DEPLOY_LOCK_WAIT="2")
        took = time.monotonic() - t0
        check(rc != 0 and 2 <= took < 10 and "result=lock-timeout" in log and "result=interrupted" not in log
              and "system-checks" not in log and "nix run" not in log
              and "gave up on acer-swift after 2s, msi-ms7758, pid 4242, def456, since 10:30:00 still deploys" in out,
              f"deploy: it gives up after DEPLOY_LOCK_WAIT ({took:.1f}s), naming the holder, and records "
              f"result=lock-timeout (rc {rc}: {out.strip()[-300:]})")
    rc, out, log = run("deploy", runtime=runtime)
    check(rc == 0 and "result=ok" in log and "result=waited" not in log,
          f"deploy: a free shared lock is taken without a wait (rc {rc})")

rc, out, log = run("dry-activate")
check(rc == 0 and "--dry-activate" in log, f"dry-activate: a passing dry activation exits 0 (rc {rc}: {out.strip()})")
check("ssh -o StrictHostKeyChecking=yes deploy@target sudo " in log and "/top/bin/switch-to-configuration dry-activate" in log
      and "diff-closures /run/current-system" in log,
      "dry-activate: it reruns on the node's hostname through the deploy user's sudo, then the closure diff")
check("would restart" not in out, "dry-activate: a passing rerun stays quiet: deploy-rs already printed its output")

rc, out, log = run("dry-activate", DRY_RC="3")
check(rc != 0 and "Completed dry-activate!" in out and "dry activation of acer-swift failed (exit 3)" in out,
      f"dry-activate: a seeded failing dry activation exits non-zero though deploy-rs reported success (rc {rc}: {out.strip()})")
check("would restart: x.service" in out and "diff-closures" in log,
      "dry-activate: the failing run's output is printed and the closure diff still runs")

rc, out, log = run("dry-activate", DIFF_RC="1")
check(rc != 0 and "closure diff on acer-swift failed (exit 1)" in out,
      f"dry-activate: a failing closure diff fails the recipe (rc {rc}: {out.strip()[-200:]})")

# the activation's user-unit warning (scripts/shadowed-user-units.sh), on homes in a temporary directory
with tempfile.TemporaryDirectory() as tmp:
    tmp = pathlib.Path(tmp)
    units = tmp / "etc-systemd-user"
    units.mkdir()
    for n in ("ollama-portforward.service", "kept.service", "linked.service"):
        (units / n).write_text(f"[Service]\nExecStart=/nix/store/x-{n}\n")
    user = tmp / "home" / "lukas" / ".config" / "systemd" / "user"
    user.mkdir(parents=True)
    (user / "ollama-portforward.service").write_text("[Service]\nExecStart=/home/lukas/bin/forward\n")
    (user / "linked.service").symlink_to(units / "linked.service")
    (user / "kept.service.d").mkdir()
    (user / "own.service").write_text("[Service]\nExecStart=/bin/true\n")
    (units / "default.target").write_text("[Unit]\n")
    (user / "default.target.wants").mkdir()
    (user / "default.target.requires").mkdir()
    other = tmp / "home" / "other"
    other.mkdir()
    r = subprocess.run(["bash", str(ROOT / "scripts/shadowed-user-units.sh"), str(tmp / "home" / "lukas"), str(other),
                        str(tmp / "absent")], env=dict(os.environ, SYSTEM_USER_UNITS=str(units)), capture_output=True, text=True)
    lines = sorted(r.stderr.splitlines())
    check(r.returncode == 0 and len(lines) == 2 and "ollama-portforward.service shadows the NixOS user unit" in lines[1]
          and "kept.service.d overrides the NixOS user unit kept.service" in lines[0],
          f"activation: a home's own copy of a NixOS user unit, and a .d override, are warned; a link to the same file, "
          f"a unit NixOS lacks, .wants and .requires directories (merged, not shadowing) and a home without the "
          f"directory are not; it never fails ({r.returncode}, {lines})")
    report = tmp / "run" / "shadowed-user-units"
    report.parent.mkdir()
    env = dict(os.environ, SYSTEM_USER_UNITS=str(units), SHADOW_REPORT=str(report))
    r = subprocess.run(["bash", str(ROOT / "scripts/shadowed-user-units.sh"), str(tmp / "home" / "lukas"), str(other)],
                       env=env, capture_output=True, text=True)
    written = sorted(report.read_text().splitlines()) if report.exists() else []
    check(r.returncode == 0 and len(written) == 2 and [f"warning: {w}" for w in written] == lines
          and oct(report.stat().st_mode & 0o777) == "0o644" and [p.name for p in report.parent.iterdir()] == [report.name],
          f"activation: with SHADOW_REPORT the same findings go to the report, readable by all, no temporary left ({written})")
    r = subprocess.run(["bash", str(ROOT / "scripts/shadowed-user-units.sh"), str(other)], env=env, capture_output=True, text=True)
    check(r.returncode == 0 and report.exists() and report.read_text() == "",
          "activation: a clean scan replaces the report with an empty one, so a fixed home clears the check")
    r = subprocess.run(["bash", str(ROOT / "scripts/shadowed-user-units.sh"), str(tmp / "home" / "lukas")],
                       env=dict(env, SHADOW_REPORT=str(tmp / "nodir" / "r")), capture_output=True, text=True)
    check(r.returncode == 0 and "could not write" in r.stderr,
          f"seeded: an unwritable report is a warning and the activation still succeeds ({r.returncode}: {r.stderr.strip()[-120:]})")

nodes = json.loads((ROOT / "flake.lock").read_text())["nodes"]
private = {n: v for n, v in nodes.items() if "sammasak" in json.dumps(v.get("original", {}))}
check(private and all(v[k]["type"] == "git" and v[k]["url"].startswith("ssh://git@github.com/sammasak/")
                      for v in private.values() for k in ("original", "locked")),
      f"flake.lock: every private input is git+ssh, fetchable without the root-only token ({sorted(private)})")

finish()
