#!/usr/bin/env python3
"""The systemd-calendar check (modules/core/systemd-verify.nix), its shell body run on fixture unit trees with this
host's systemd-analyze: every OnCalendar= of the system and user timers and their drop-ins must parse, an empty
OnCalendar= (a drop-in's reset) is skipped, a tree with no OnCalendar= at all fails as not this host's, and a typo in
one spec fails the check naming the timer, also in a Home Manager user's timers, naming the user."""
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
m = re.search(r'\(pkgs\.runCommand "systemd-calendar" \{[^}]*\} \'\'\n(.*?)\n    \'\'\)', module, re.DOTALL)
check(m is not None, "systemd-verify.nix has the systemd-calendar runCommand")
if m is None:
    sys.exit(1)
body = m.group(1).replace("''${", "${")


def run(timers, hm={}):
    """timers: {relative path under etc/systemd: unit text}; hm: {user: {path under systemd/user: text}}
    -> (rc, output, out written)"""
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        for rel, text in timers.items():
            p = tmp / "etc/systemd" / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text)
        trees = []
        for user, files in hm.items():
            for rel, text in files.items():
                p = tmp / "hm" / user / rel
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text(text)
            trees.append(f"{user}={tmp / 'hm' / user}")
        work = tmp / "build"
        work.mkdir()
        script = body.replace("${config.system.build.etc}", str(tmp)).replace("${hmTrees}", " ".join(trees))
        r = subprocess.run(["bash", "-euo", "pipefail", "-c", script], cwd=work, capture_output=True, text=True, check=False,
                           env=dict(os.environ, out=str(tmp / "out")))
        return r.returncode, r.stdout + r.stderr, (tmp / "out").exists()


if shutil.which("systemd-analyze") is None:
    check(False, "systemd-analyze is on PATH")
    sys.exit(1)

good = "[Timer]\nOnCalendar=Mon-Fri 08:30\nOnCalendar=daily\n"
rc, out, made = run({"system/a.timer": good, "user/b.timer": "[Timer]\nOnCalendar=*-*-* 03:00:00\n",
                     "system/a.timer.d/override.conf": "[Timer]\nOnCalendar=\nOnCalendar=weekly\n"})
check(rc == 0 and made and "4 OnCalendar= specs parse" in out,
      f"a tree whose specs all parse passes, counting system, user and drop-in specs and skipping the reset ({rc}, {out.strip()!r})")
rc, out, made = run({"system/a.timer": good, "system/msi-wake.timer": "[Timer]\nOnCalendar=Mon-Fri 25:00\n"})
check(rc != 0 and not made and "system/msi-wake.timer: OnCalendar=Mon-Fri 25:00 does not parse" in out,
      f"seeded: one bad spec fails the check and names its timer ({rc}, {out.strip()!r})")
rc, out, made = run({"user/c.timer.d/x.conf": "[Timer]\nOnCalendar=Mon-Fry 09:00\n", "system/a.timer": good})
check(rc != 0 and "user/c.timer.d/x.conf: OnCalendar=Mon-Fry 09:00 does not parse" in out,
      f"seeded: a bad spec in a user timer's drop-in fails too ({rc}, {out.strip()!r})")
hm = {"lukas": {"repo-sweep.timer": "[Timer]\nOnCalendar=*-*-* 04:00:00\n",
                "timers.target.wants/repo-sweep.timer": "[Timer]\nOnCalendar=*-*-* 04:00:00\n"}}
rc, out, made = run({"system/a.timer": good}, hm)
check(rc == 0 and made and "3 OnCalendar= specs parse" in out,
      f"a Home Manager user's timer is counted once, not again through timers.target.wants ({rc}, {out.strip()!r})")
hm = {**hm, "guest": {"coordinator-wakeup.timer": "[Timer]\nOnCalendar=Mon-Fry 09:00\n"}}
rc, out, made = run({"system/a.timer": good}, hm)
check(rc != 0 and not made and "home-manager guest: coordinator-wakeup.timer: OnCalendar=Mon-Fry 09:00 does not parse" in out,
      f"seeded: a bad spec in a Home Manager user timer fails, naming the user and timer ({rc}, {out.strip()!r})")
rc, out, made = run({"system/a.service": "[Service]\nExecStart=/bin/true\n"})
check(rc != 0 and not made and "no OnCalendar= in this host's timers" in out,
      f"a tree without any OnCalendar= fails as not this host's ({rc}, {out.strip()!r})")

sys.exit(1 if failed else 0)
