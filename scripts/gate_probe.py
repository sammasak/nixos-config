"""A test's section of scripts/gate-probe.nix: the probe nixos:qa built once (GATE_PROBE), or, for a test run on
its own, a probe of that section alone. As a command it prints the section, for the shell gates.
Also the tests' shared check()/finish() and flipped(); a test importing them needs its script dir on sys.path
(`python scripts/test-X.py`, not `python -I`)."""
import json
import os
import pathlib
import shutil
import subprocess
import sys

failed = 0
OWNER = "scripts/" + os.path.basename(sys.argv[0])


def check(ok, what):
    """A FAIL line names the test that printed it: the gate interleaves several tests' output."""
    global failed
    print(("PASS: " if ok else f"FAIL ({OWNER}): ") + what)
    failed += not ok


def finish():
    sys.exit(1 if failed else 0)


def flipped(skills, tmp, has, hooks, probe, missing_ok=False):
    """The pinned skills tree with the hooks added (stubs) when it lacks them, or removed when it has them, evaluated
    through the probe (a scripts/*-probe.nix) with the skills input overridden."""
    root = pathlib.Path(__file__).resolve().parent.parent
    fixture = pathlib.Path(tmp, "skills")
    shutil.copytree(skills, fixture, symlinks=True)
    for p in [fixture, *fixture.rglob("*")]:
        if not p.is_symlink():
            p.chmod(p.stat().st_mode | 0o200)
    for h in hooks:
        f = fixture / "hooks" / h
        if has:
            f.unlink(missing_ok=missing_ok)
        else:
            f.write_text("#!/bin/sh\nexit 0\n")
            f.chmod(0o755)
    out = subprocess.run(
        ["nix", "eval", "--json", "--impure", "--no-write-lock-file", "--override-input", "skills", f"path:{fixture}",
         f"{root}#nixosConfigurations", "--apply", f"import {root}/scripts/{probe}"],
        capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"nix eval with the flipped skills source failed:\n{out.stderr[-800:]}")
    return json.loads(out.stdout)


def section(name):
    path = os.environ.get("GATE_PROBE") or subprocess.run(
        ["nix", "build", "--impure", "--no-link", "--print-out-paths", "--expr",
         f'(import ./scripts/gate-probe.nix {{ only = [ "{name}" ]; }}).json'],
        check=True, stdout=subprocess.PIPE, text=True).stdout.strip()
    with open(path) as f:
        return json.load(f)[name]


if __name__ == "__main__":
    print(json.dumps(section(sys.argv[1])))
