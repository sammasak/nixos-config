"""nixos-flake-check's deferral rule (#502) for a build a gate step makes outside the flake check: the to-build list of a
dry-run, and a build whose to-build inputs match the heavy pattern runs on its own node only. The pattern is devenv.nix's
gateHeavy, the one the flake check uses, handed over as GATE_HEAVY; scripts/test-gate-steps.py runs this parse and the
flake check's awk on the same dry-run texts."""
import os
import re
import subprocess
import sys


def to_build(text):
    """The derivations a dry-run says it would build: the indented lines after "will be built:", up to "will be fetched"
    or the next unindented line (the flake check's awk)."""
    todo, inside = [], False
    for line in text.splitlines():
        if "will be built:" in line:
            inside = True
        elif "will be fetched" in line or not line.startswith(" "):
            inside = False
        elif inside:
            todo.append(line.split()[0])
    return todo


def deferred(drv, name, owner, step):
    """None to build drv here, else (derivations it would compile, the heavy inputs it would compile against). A dry-run
    that fails, or does not know how to build drv, ends the step."""
    heavy = re.compile(os.environ["GATE_HEAVY"])
    dry = subprocess.run(["nix", "build", "--dry-run", "--no-link", drv + "^*"], capture_output=True, text=True, check=False)
    text = dry.stdout + dry.stderr
    if dry.returncode != 0 or "know how to build" in text:
        print(text, file=sys.stderr)
        sys.exit(f"{step}: the dry-run of {name} failed")
    todo = to_build(text)
    if not todo or os.uname().nodename.startswith(owner):
        return None
    refs = subprocess.run(["nix-store", "-q", "--references", *todo], capture_output=True, text=True, check=False).stdout.split()
    hits = sorted({re.sub(r"^/nix/store/[a-z0-9]*-", "", r) for r in refs if heavy.search(r)})
    return (len(todo), hits) if hits else None
