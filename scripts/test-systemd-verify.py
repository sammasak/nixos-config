#!/usr/bin/env python3
"""The systemd-verify check (modules/core/systemd-verify.nix), its shell body run on fixture unit trees with this host's
systemd-analyze: a clean tree passes, and so does the allowlisted user-mode message; any file:line message systemd
logs (an unknown key or section, a value, memory or CPU limit that does not parse, a bad dependency name, a path that
is not absolute, a removed option, in a unit or its drop-in) and any unit it refuses ("has a bad unit file setting")
in a unit multi-user.target wants fails the check, printing the line; and a check whose pattern no longer
matches systemd's message fails on the fixture Restartsec= instead of passing the tree. Each Home Manager user's units
(a timers.target.wants copy included) are verified file by file: a misspelt key or a bad drop-in value there fails the
check naming the user, a check that skips the user fixture fails, and a host with no Home Manager unit fails."""
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


module = (ROOT / "modules/core/systemd-verify.nix").read_text()
m = re.search(r'\(pkgs\.runCommand "systemd-verify" \{[^}]*\} \'\'\n(.*?)\n    \'\'\)', module, re.DOTALL)
check(m is not None, "systemd-verify.nix has the systemd-verify runCommand")
if m is None:
    sys.exit(1)
body = m.group(1).replace("''${", "${")
true = shutil.which("true")


HM_CLEAN = {"lukas": {"tray.target": "[Unit]\nDescription=tray\n"}}


def run(extra, script=body, dropins={}, hm=HM_CLEAN):
    """extra: {unit name: text}, each wanted by multi-user.target; dropins: {path under the unit dir: text};
    hm: {user: {path under systemd/user: text}} -> (rc, output, out written)"""
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        system = tmp / "etc/systemd/system"
        (system / "multi-user.target.wants").mkdir(parents=True)
        # basic.target and shutdown.target: a service's default dependencies, without which its job is dropped
        for target in ("multi-user.target", "basic.target", "shutdown.target"):
            (system / target).write_text("[Unit]\n")
        (system / "default.target").symlink_to("multi-user.target")
        units = {f"s{i}.service": f"[Service]\nExecStart={true}\n" for i in range(21)}
        for name, text in {**units, **extra}.items():
            (system / name).write_text(text)
            (system / "multi-user.target.wants" / name).symlink_to(f"../{name}")
        for rel, text in dropins.items():
            (system / rel).parent.mkdir(parents=True, exist_ok=True)
            (system / rel).write_text(text)
        trees = []
        for user, files in hm.items():
            for rel, text in files.items():
                p = tmp / "hm" / user / rel
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text(text)
            trees.append(f"{user}={tmp / 'hm' / user}")
        work = tmp / "build"
        work.mkdir()
        script = (script.replace("${config.system.build.etc}", str(tmp)).replace("${trueBin}", true)
                  .replace("${hmTrees}", " ".join(trees)))
        r = subprocess.run(["bash", "-euo", "pipefail", "-c", script], cwd=work, capture_output=True, text=True, check=False,
                           env=dict(os.environ, out=str(tmp / "out")))
        return r.returncode, r.stdout + r.stderr, (tmp / "out").exists()


if shutil.which("systemd-analyze") is None:
    check(False, "systemd-analyze is on PATH")
    sys.exit(1)

rc, out, made = run({})
check(rc == 0 and made, f"a clean tree passes, the fixture cycle and Restartsec= reported first ({rc}, {out.strip()!r})")
for what, text, line in [
    ("an unknown key", "[Service]\nRestartsec=5\nExecStart=/bin/true\n", "Unknown key 'Restartsec'"),
    ("an unknown section", "[Servce]\nExecStart=/bin/true\n", "Unknown section 'Servce'"),
    ("a value that does not parse", "[Service]\nType=simpel\nExecStart=/bin/true\n", "Failed to parse Type=simpel"),
    ("a memory limit that does not parse", "[Service]\nMemoryMax=8Gb\nExecStart=/bin/true\n", "Invalid memory limit '8Gb'"),
    ("a CPU quota that does not parse", "[Service]\nCPUQuota=800\nExecStart=/bin/true\n", "Invalid CPU quota '800'"),
    ("a path that is not absolute (message without 'ignoring')", "[Service]\nWorkingDirectory=relative\nExecStart=/bin/true\n",
     "WorkingDirectory= path is not absolute"),
    ("a bad dependency name", "[Unit]\nOnFailure=not a unit\n[Service]\nExecStart=/bin/true\n", "Failed to add dependency on not"),
    ("a removed option (message says 'ignored', not 'ignoring')", "[Service]\nMemoryLimit=1G\nExecStart=/bin/true\n",
     "Support for option MemoryLimit= has been removed"),
]:
    rc, out, made = run({"msi-wake.service": text})
    check(rc != 0 and not made and "unit lines systemd rejects, ignores or warns about, reaching multi-user.target:" in out
          and re.search(r"msi-wake\.service:\d+: " + re.escape(line), out) is not None,
          f"seeded: {what} fails the check and prints the line ({rc}, {out.strip()!r})")

# refusals systemd states only as a verdict, with no file:line: the "has a bad unit file setting" branch catches them
REFUSED = [
    ("Restart=always on a oneshot", "[Service]\nType=oneshot\nRestart=always\nExecStart=/bin/true\n"),
    ("two ExecStart= on a non-oneshot service", "[Service]\nExecStart=/bin/true\nExecStart=/bin/true\n"),
]
for what, text in REFUSED:
    rc, out, made = run({"msi-wake.service": text})
    check(rc != 0 and not made and "unit lines systemd rejects, ignores or warns about, reaching multi-user.target:" in out
          and "msi-wake.service has a bad unit file setting" in out,
          f"seeded: {what} (refused, no file:line) fails the check ({rc}, {out.strip()!r})")
no_verdict = body.replace("|has a bad unit file setting'", "'")
check(no_verdict != body, "the check's verdict branch is found to drop it")
rc, out, made = run({"msi-wake.service": REFUSED[0][1]}, no_verdict)
check(rc == 0 and made, f"without the verdict branch a refused unit passes: the branch is what catches it ({rc}, {out.strip()!r})")

rc, out, made = run({}, dropins={"s0.service.d/override.conf": "[Service]\nRestartSec=5x\n"})
check(rc != 0 and not made and re.search(r"s0\.service\.d/override\.conf:\d+: Failed to parse RestartSec=5x", out) is not None,
      f"seeded: a value that does not parse in a drop-in fails too ({rc}, {out.strip()!r})")
rc, out, made = run({"reboot.service": "[Unit]\nSuccessAction=soft-reboot-force\n[Service]\nExecStart=/bin/true\n"})
check(rc == 0 and made, f"the allowlisted user-mode message (a system action in *Action=) passes ({rc}, {out.strip()!r})")

timer = "[Timer]\nOnCalendar=daily\n"
hm = {"lukas": {"repo-sweep.service": f"[Service]\nExecStart={true}\n", "repo-sweep.timer": timer,
                "timers.target.wants/repo-sweep.timer": timer},
      "guest": {"tray.target": "[Unit]\n"}}
rc, out, made = run({}, hm=hm)
check(rc == 0 and made, f"clean Home Manager trees of two users, with a .wants copy, pass ({rc}, {out.strip()!r})")
bad = {**hm, "guest": {"herdr.service": f"[Service]\nRestartsec=5\nExecStart={true}\n"}}
rc, out, made = run({}, hm=bad)
check(rc != 0 and not made and "guest's Home Manager unit lines systemd rejects, ignores or warns about:" in out
      and re.search(r"herdr\.service:\d+: Unknown key 'Restartsec'", out) is not None,
      f"seeded: a misspelt key in a Home Manager user unit fails, naming the user and the line ({rc}, {out.strip()!r})")
rc, out, made = run({}, hm={"lukas": {"herdr.service": f"[Service]\nExecStart={true}\n",
                                      "herdr.service.d/x.conf": "[Service]\nRestartSec=5x\n"}})
check(rc != 0 and not made and re.search(r"herdr\.service\.d/x\.conf:\d+: Failed to parse RestartSec=5x", out) is not None,
      f"seeded: a bad value in a Home Manager unit's drop-in fails ({rc}, {out.strip()!r})")
rc, out, made = run({}, hm={})
check(rc != 0 and not made and "no Home Manager user unit on this host" in out,
      f"a host without any Home Manager unit fails as not this host's ({rc}, {out.strip()!r})")
skips = body.replace("hmverify hm/fixture-c.service", "hmverify hm/tray.target")
check(skips != body, "the user fixture's verify is found to skip it")
rc, out, made = run({}, skips)
check(rc != 0 and not made and "the fixture Restartsec= in lukas's Home Manager units was not reported" in out,
      f"seeded: a check that does not verify the user fixture fails, not passing the users ({rc}, {out.strip()!r})")

blind = body.replace("':[0-9]+: |has a bad", "':[0-9]+: .*ignored|has a bad")
check(blind != body, "the check's pattern is found to blind it")
rc, out, made = run({"msi-wake.service": "[Service]\nRestartsec=5\nExecStart=/bin/true\n"}, blind)
check(rc != 0 and not made and "the fixture Restartsec= under multi-user.target was not reported" in out,
      f"seeded: a pattern that misses systemd's message fails on the fixture, not passing the tree ({rc}, {out.strip()!r})")

sys.exit(1 if failed else 0)
