#!/usr/bin/env python3
"""pkgs/nixos-textfile against the shell version it replaced, over fixture trees of toplevels and profiles: for
every input the shell handled, nixos.prom byte for byte and the exit code, as captured from the shell writer
into scripts/fixtures/nixos-textfile-parity.json. Where the shell went quiet (a missing nixos-version written as
version="", a missing toplevel leaving the previous file), the port's explicit failure is checked instead.
Usage: test-nixos-textfile.py PORT FIXTURE                  compare (the flake check)
       test-nixos-textfile.py --capture OLD_SH FIXTURE      rewrite the fixture from the shell version"""

import json
import os
import pathlib
import subprocess
import sys
import tempfile

CAPTURE = sys.argv[1] == "--capture"
TOOL, FIXTURE = (os.path.abspath(x) for x in sys.argv[2 if CAPTURE else 1:][:2])
PREVIOUS = "homelab_nixos_generation 1\n"


def toplevel(root: str, name: str, version: str | None = "26.11pre-git") -> str:
    """A store toplevel: its own activate script and, unless None, nixos-version."""
    d = os.path.join(root, "store", name)
    os.makedirs(d)
    pathlib.Path(d, "activate").write_text("#!/bin/sh\n# " + name + "\n")
    if version is not None:
        pathlib.Path(d, "nixos-version").write_text(version + "\n")
    return d


def activatable(root: str, system: str) -> str:
    """deploy-rs's buildEnv around a toplevel: its activate links to the toplevel's."""
    d = os.path.join(root, "store", "activatable-" + os.path.basename(system))
    os.makedirs(d)
    os.symlink(os.path.join(system, "activate"), os.path.join(d, "activate"))
    return d


def profiles(root: str, name: str, links: dict[str, str], current: str | None) -> str:
    d = os.path.join(root, name)
    os.makedirs(d)
    for link, target in links.items():
        os.symlink(target, os.path.join(d, link))
    if current:
        os.symlink(current, os.path.join(d, "system"))
    return d


def run(root: str, system: str, prof: str) -> dict[str, object]:
    out = os.path.join(root, "out-" + os.path.basename(prof))
    os.makedirs(out, exist_ok=True)
    pathlib.Path(out, "nixos.prom").write_text(PREVIOUS)
    argv = ["bash", TOOL] if CAPTURE else [sys.executable, "-I", TOOL]
    p = subprocess.run([*argv, out, system, prof], capture_output=True, text=True, env={**os.environ, "LC_ALL": "C.UTF-8"})
    files = sorted(os.listdir(out))
    return {"rc": p.returncode, "prom": pathlib.Path(out, "nixos.prom").read_text(), "files": files}


def cases(root: str) -> dict[str, dict[str, object]]:
    a = toplevel(root, "aaaa1111-nixos-system-host-26.11")
    b = toplevel(root, "bbbb2222-nixos-system-host-26.11")
    c = toplevel(root, "cccc3333-nixos-system-host-26.11", version='26.11 "quoted"')
    got = {}
    # deploy-rs: the profile holds activatable buildEnvs; the current one is the activated system
    got["deploy-rs-current"] = run(root, a, profiles(root, "p1", {"system-27-link": activatable(root, a),
                                                                  "system-26-link": activatable(root, b)}, "system-27-link"))
    # nixos-rebuild: toplevels in the profile; booted into 3 while the profile is at 4
    got["rebuild-booted-older"] = run(root, a, profiles(root, "p2", {"system-3-link": a, "system-4-link": b}, "system-4-link"))
    # two links to the same system: the newest
    got["newest-of-two"] = run(root, a, profiles(root, "p3", {"system-9-link": a, "system-10-link": a, "system-11-link": b},
                                                 "system-11-link"))
    # a specialisation or a test switch: no link holds it, so no generation line
    got["no-generation"] = run(root, c, profiles(root, "p4", {"system-5-link": a}, "system-5-link"))
    # a link name that is not a number is only taken first; the shell's -gt refuses it after
    got["odd-link-name"] = run(root, a, profiles(root, "p5", {"system-7-link": a, "system-x-link": a}, "system-x-link"))
    # an empty profile directory
    got["empty-profiles"] = run(root, a, profiles(root, "p6", {}, None))
    # the activated path given through a symlink, as $systemConfig may be
    os.symlink(a, os.path.join(root, "store", "result"))
    got["system-through-link"] = run(root, os.path.join(root, "store", "result"), profiles(root, "p7", {"system-2-link": a},
                                                                                           "system-2-link"))
    # where the shell went quiet: recorded as captured, checked as findings below
    got["no-nixos-version"] = run(root, toplevel(root, "dddd4444-nixos-system-host", version=None), profiles(root, "p8", {}, None))
    got["no-toplevel"] = run(root, os.path.join(root, "gone", "eeee5555-nixos-system-host"), profiles(root, "p9", {}, None))
    return got


FINDINGS = {
    # the shell wrote version="" and exited 0; the port names it
    "no-nixos-version": {"rc": 1, "prom": 'homelab_nixos_textfile_failed{reason="version-unreadable"} 1\n'},
    # the shell stopped under set -e and left the previous file (the activation's || true hid it); the port replaces it
    "no-toplevel": {"rc": 1, "prom": 'homelab_nixos_textfile_failed{reason="system-missing"} 1\n'},
}
failed = 0


def check(ok: bool, what: str) -> None:
    global failed
    failed += not ok
    print(("PASS: " if ok else "FAIL: ") + what)


with tempfile.TemporaryDirectory() as root:
    got = cases(root)
    if CAPTURE:
        pathlib.Path(FIXTURE).write_text(json.dumps(got, indent=1, sort_keys=True) + "\n")
        print(f"captured {len(got)} cases from {TOOL}")
        sys.exit(0)
    want = json.load(open(FIXTURE))
    for name, g in got.items():
        w = want[name]
        if name in FINDINGS:
            f = FINDINGS[name]
            check(g["rc"] == f["rc"] and g["prom"] == f["prom"] and g["files"] == ["nixos.prom"],
                  f"{name}: the shell's {w['rc']} with {w['prom']!r} becomes an explicit failure ({g})")
        else:
            check(g == w, f"{name}: nixos.prom, its exit code and the directory as the shell's" + ("" if g == w else f"\n  want {w}\n  got  {g}"))
    # the seeded shell behaviours the findings replace, so the fixture keeps showing what the shell did
    check(want["no-nixos-version"]["rc"] == 0 and 'version=""' in want["no-nixos-version"]["prom"],
          "seeded: the shell wrote an empty version and exited 0 when nixos-version was missing")
    check(want["no-toplevel"]["rc"] != 0 and want["no-toplevel"]["prom"] == PREVIOUS,
          "seeded: the shell failed and left the previous file when the toplevel was missing")
    # a directory it cannot write: exit 1, the error on stderr
    ro = os.path.join(root, "ro")
    os.makedirs(ro)
    os.chmod(ro, 0o555)
    a = os.path.join(root, "store", "aaaa1111-nixos-system-host-26.11")
    p = subprocess.run([sys.executable, "-I", TOOL, ro, a, os.path.join(root, "p1")], capture_output=True, text=True)
    os.chmod(ro, 0o755)
    check(p.returncode == 1 and "cannot write" in p.stderr if os.geteuid() != 0 else True,
          f"an unwritable directory exits 1 and says why ({p.returncode}, {p.stderr.strip()[:120]!r})")

print(f"{'FAIL' if failed else 'ok'}: {failed} failed")
sys.exit(1 if failed else 0)
