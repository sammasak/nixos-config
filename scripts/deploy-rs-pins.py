#!/usr/bin/env python3
"""The deploy-rs rev pinned three times must agree: devenv.yaml's url (the devenv shell's deploy CLI), devenv.lock and
flake.lock (the flake's input, which the Justfile's `nix run --inputs-from . deploy-rs` and every host's activation
use). The deploy CLI must match the activation side, and the weekly flake.lock update moves only flake.lock.
Exit 0 when all three agree, 1 when they differ (each file's rev printed), 2 when one cannot be read: unknown is never
a pass. --seeds runs the check on copies with one rev changed in each file and on a copy missing a pin, and exits 1
unless each is caught. Standard library only, no Nix: it runs in the lints lane (devenv.nix `lints`)."""
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
FILES = ("devenv.yaml", "devenv.lock", "flake.lock")
YAML = re.compile(r"^  deploy-rs:\n    url: github:serokell/deploy-rs/([0-9a-f]{40})\s*$", re.M)


def lock_rev(path):
    """The rev of the node the lock's root input `deploy-rs` resolves to."""
    lock = json.loads(path.read_text())
    node = lock["nodes"][lock["root"]]["inputs"]["deploy-rs"]
    if not isinstance(node, str):
        raise KeyError(f"root input deploy-rs follows {node}, not a node of its own")
    return lock["nodes"][node]["locked"]["rev"]


def revs(root):
    """{file: rev}, or {file: None} with the reason printed, for each of FILES under root."""
    out = {}
    for name in FILES:
        path = root / name
        try:
            if name.endswith(".yaml"):
                m = YAML.search(path.read_text())
                if not m:
                    raise KeyError("no `deploy-rs:` input with a `url: github:serokell/deploy-rs/<40-hex rev>`")
                out[name] = m[1]
            else:
                out[name] = lock_rev(path)
        except (OSError, ValueError, KeyError, TypeError) as e:
            print(f"deploy-rs-pins: cannot read the deploy-rs rev from {name}: {e}", file=sys.stderr)
            out[name] = None
    return out


def check(root):
    found = revs(root)
    if None in found.values():
        return 2
    if len(set(found.values())) == 1:
        print(f"deploy-rs-pins: devenv.yaml, devenv.lock and flake.lock all pin {next(iter(found.values()))}")
        return 0
    print("deploy-rs-pins: the deploy-rs pins differ; the deploy CLI must match the activation side:", file=sys.stderr)
    for name, rev in found.items():
        print(f"  {name}: {rev}", file=sys.stderr)
    return 1


def seeds():
    """Each file's rev changed in a copy, and a copy with devenv.yaml's pin gone: each must be caught."""
    bad = "0" * 40
    failed = 0
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        for name in FILES:
            for f in FILES:
                shutil.copy(ROOT / f, tmp / f)
            rev = revs(ROOT)[name]
            text = (tmp / name).read_text()
            assert rev and text.count(rev) >= 1, f"seed: {name} has no rev to change"
            (tmp / name).write_text(text.replace(rev, bad))
            r = subprocess.run([sys.executable, __file__, str(tmp)], capture_output=True, text=True)
            ok = r.returncode == 1 and f"{name}: {bad}" in r.stderr and rev in r.stderr
            print(f"{'PASS' if ok else 'FAIL'}: seeded: {name} pinning another rev fails with both revs printed ({r.returncode})")
            failed |= not ok
        for f in FILES:
            shutil.copy(ROOT / f, tmp / f)
        (tmp / "devenv.yaml").write_text(YAML.sub("", (tmp / "devenv.yaml").read_text()))
        r = subprocess.run([sys.executable, __file__, str(tmp)], capture_output=True, text=True)
        ok = r.returncode == 2 and "cannot read the deploy-rs rev from devenv.yaml" in r.stderr
        print(f"{'PASS' if ok else 'FAIL'}: seeded: devenv.yaml without its deploy-rs pin is unknown, exit 2, not a pass ({r.returncode})")
        failed |= not ok
    return 1 if failed else 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--seeds"]:
        sys.exit(seeds())
    sys.exit(check(pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT))
