#!/usr/bin/env python3
"""The systemd-verify check (modules/core/systemd-verify.nix), its shell body run on fixture unit trees with this host's
systemd-analyze: a clean tree passes; an unknown key, an unknown section or a value that does not parse in a unit
multi-user.target wants fails the check, printing the line; and a check whose pattern no longer matches systemd's
message fails on the fixture Restartsec= instead of passing the tree."""
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


def run(extra, script=body):
    """extra: {unit name: text}, each wanted by multi-user.target -> (rc, output, out written)"""
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
        work = tmp / "build"
        work.mkdir()
        script = script.replace("${config.system.build.etc}", str(tmp)).replace("${trueBin}", true)
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
]:
    rc, out, made = run({"msi-wake.service": text})
    check(rc != 0 and not made and "unit lines systemd ignores, reaching multi-user.target:" in out
          and re.search(r"msi-wake\.service:\d+: " + re.escape(line), out) is not None,
          f"seeded: {what} fails the check and prints the line ({rc}, {out.strip()!r})")

blind = body.replace("Unknown key|Unknown section|Failed to parse", "Unknown keys|Unknown sections|Failed to parse:")
check(blind != body, "the check's pattern is found to blind it")
rc, out, made = run({"msi-wake.service": "[Service]\nRestartsec=5\nExecStart=/bin/true\n"}, blind)
check(rc != 0 and not made and "the fixture Restartsec= under multi-user.target was not reported" in out,
      f"seeded: a pattern that misses systemd's message fails on the fixture, not passing the tree ({rc}, {out.strip()!r})")

sys.exit(1 if failed else 0)
