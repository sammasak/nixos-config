#!/usr/bin/env python3
"""What evaluated, per git tree (#900): one JSON file per HEAD^{tree} in $XDG_STATE_HOME/nixos-eval-records (default
~/.local/state, beside platform-records), so the push hook, pool-merge-check and the flake check do not evaluate one
tree twice. A record holds the nix that evaluated it (`nix --version`: another nix is another key), flake_show=ok with
the output kinds that `nix flake show --json --all-systems --no-write-lock-file` listed, and each host's toplevel
drvPath. Per user: a pool slot's records are its own HOME's, the host's sessions and the scheduled gate share the
owner's.

Written only for a clean checkout (nothing staged, modified or untracked, no skip-worktree or sparse checkout, no
GIT_DIR from a caller) whose tree is the one the caller saw before its evaluation: a git flake reads the tracked files
as checked out, so only then is the tree the input. Read only for such a checkout too, and never for another tree or
another nix; a file that does not parse or holds a field in the wrong shape reads as no record. NIXOS_EVAL_RECORD=0
turns every read off (the writers still write), to compare the saving or step around a bad record. A recorded drvPath
may have been garbage collected since: a reader that builds from it must evaluate again.

Usage: eval_record.py tree                 this checkout's tree when it is clean, else exit 1
       eval_record.py flake-show           the recorded output kinds of this checkout's tree, else exit 1
       eval_record.py put TREE [--flake-kinds JSON] [--toplevels FILE]
                                           record them for TREE, if this checkout is still TREE and clean; FILE has
                                           "host drv" lines (the flake check's NIXOS_QA_TOPLEVELS). Never fails."""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time

TREE = re.compile(r"[0-9a-f]{40}(?:[0-9a-f]{24})?")
DRV = re.compile(r"/nix/store/[0-9a-z]{32}-[^/\s]+\.drv")
HOST = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
KEEP_DAYS = 30


def say(text: str) -> None:
    print(f"eval-record: {text}", file=sys.stderr, flush=True)


def directory() -> pathlib.Path:
    state = os.environ.get("XDG_STATE_HOME") or str(pathlib.Path.home() / ".local/state")
    return pathlib.Path(state) / "nixos-eval-records"


def reading() -> bool:
    return os.environ.get("NIXOS_EVAL_RECORD") != "0"


def git(repo: pathlib.Path, *args: str) -> str | None:
    r = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=False)
    return r.stdout if r.returncode == 0 else None


def clean_tree(repo: pathlib.Path) -> str | None:
    """repo's HEAD tree when the checkout holds nothing else (as scripts/qa-green.sh judges it), else None."""
    if any(os.environ.get(v) for v in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE")):
        return None
    status = git(repo, "status", "--porcelain", "--untracked-files=all")
    flags = git(repo, "ls-files", "-v")
    sparse = git(repo, "config", "--bool", "core.sparseCheckout")
    tree = git(repo, "rev-parse", "HEAD^{tree}")
    if status != "" or flags is None or re.search(r"^[a-zS]", flags, re.MULTILINE) or (sparse or "").strip() == "true":
        return None
    tree = (tree or "").strip()
    return tree if TREE.fullmatch(tree) else None


def nix_version() -> str | None:
    try:
        r = subprocess.run(["nix", "--version"], capture_output=True, text=True, check=False, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    v = r.stdout.strip()
    return v if r.returncode == 0 and v and "\n" not in v else None


def valid(rec: object, tree: str, nix: str) -> dict | None:
    """rec when it is this tree's and this nix's record, every field in its shape; else None (a miss)."""
    if not isinstance(rec, dict) or rec.get("tree") != tree or rec.get("nix") != nix:
        return None
    if set(rec) - {"tree", "nix", "flake_show", "flake_kinds", "toplevel"}:
        return None
    if "flake_show" in rec:
        try:
            kinds = json.loads(rec.get("flake_kinds"))
        except (TypeError, ValueError):
            return None
        if rec["flake_show"] != "ok" or not isinstance(kinds, list) or not all(isinstance(k, str) for k in kinds):
            return None
    elif "flake_kinds" in rec:
        return None
    tops = rec.get("toplevel", {})
    if not isinstance(tops, dict) or not all(isinstance(h, str) and HOST.fullmatch(h) and isinstance(d, str)
                                             and DRV.fullmatch(d) for h, d in tops.items()):
        return None
    return rec


def load(tree: str, nix: str) -> dict | None:
    try:
        return valid(json.loads((directory() / f"{tree}.json").read_text()), tree, nix)
    except (OSError, ValueError, UnicodeDecodeError):
        return None


def lookup(repo: pathlib.Path) -> dict | None:
    """The record of repo's tree under this nix, when reading is on and the checkout is clean."""
    if not reading():
        say("NIXOS_EVAL_RECORD=0: no record read")
        return None
    tree = clean_tree(repo)
    nix = nix_version() if tree else None
    return load(tree, nix) if tree and nix else None


def flake_show(repo: pathlib.Path) -> str | None:
    """The output kinds (as `jq -c keys` prints them) of a recorded passing flake show of repo's tree."""
    rec = lookup(repo)
    return rec["flake_kinds"] if rec and rec.get("flake_show") == "ok" else None


def toplevels(repo: pathlib.Path) -> dict[str, str]:
    rec = lookup(repo)
    return dict(rec.get("toplevel", {})) if rec else {}


def baselines(repo: pathlib.Path, hosts: list[str]) -> dict[str, str]:
    """The recorded toplevels of repo's tree when they cover every one of hosts, else none: a partial record (a
    pool-merge-check that evaluated some hosts) would leave a check that compares them all short of some."""
    tops = toplevels(repo)
    return tops if tops and set(hosts) <= set(tops) else {}


def kinds_of(show: str) -> str:
    """`nix flake show --json` output's kinds as `jq -c keys` prints them."""
    return json.dumps(sorted(json.loads(show)), separators=(",", ":"))


@contextlib.contextmanager
def locked(d: pathlib.Path):
    fd = os.open(d / ".lock", os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def put(repo: pathlib.Path, tree: str, flake_kinds: str | None = None, tops: dict[str, str] | None = None) -> bool:
    """Record what evaluated for tree, if repo is still that clean tree. Merged into the tree's record under a lock
    (several slots and the gate write), written whole to a temporary file and renamed, so a reader sees the old record
    or the new one. Whether it was written; a failure is said, never raised."""
    try:
        return _put(repo, tree, flake_kinds, tops or {})
    except (OSError, ValueError) as e:
        say(f"not recorded: {e}")
        return False


def _put(repo: pathlib.Path, tree: str, flake_kinds: str | None, tops: dict[str, str]) -> bool:
    if flake_kinds is None and not tops:
        return False
    now = clean_tree(repo)
    if not TREE.fullmatch(tree) or now != tree:
        say(f"not recorded: the checkout is not clean tree {tree[:12]} now ({(now or 'dirty')[:12]})")
        return False
    nix = nix_version()
    if not nix:
        say("not recorded: no nix --version")
        return False
    new: dict = {"tree": tree, "nix": nix}
    if flake_kinds is not None:
        new.update(flake_show="ok", flake_kinds=flake_kinds)
    if tops:
        new["toplevel"] = tops
    if not valid(new, tree, nix):
        say(f"not recorded: a value is not in its shape ({new})")
        return False
    d = directory()
    d.mkdir(parents=True, exist_ok=True)
    with locked(d):
        rec = load(tree, nix) or {"tree": tree, "nix": nix}
        rec.update({k: v for k, v in new.items() if k != "toplevel"})
        rec["toplevel"] = {**rec.get("toplevel", {}), **tops}
        if not rec["toplevel"]:
            del rec["toplevel"]
        with tempfile.NamedTemporaryFile("w", dir=d, prefix=".new-", delete=False) as f:
            json.dump(rec, f, sort_keys=True)
        os.replace(f.name, d / f"{tree}.json")
        # records of trees not evaluated for a month, and a writer's temporary file an interrupt left behind
        old = time.time() - KEEP_DAYS * 86400
        for p in [*d.glob("*.json"), *d.glob(".new-*")]:
            with contextlib.suppress(OSError):
                if p.stat().st_mtime < (old if p.suffix == ".json" else time.time() - 86400):
                    p.unlink()
    return True


def read_toplevels(path: pathlib.Path) -> dict[str, str]:
    pairs = [line.split() for line in path.read_text().splitlines() if line.strip()]
    return {p[0]: p[1] for p in pairs if len(p) == 2}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("tree")
    sub.add_parser("flake-show")
    p = sub.add_parser("put")
    p.add_argument("tree")
    p.add_argument("--flake-kinds")
    p.add_argument("--toplevels", type=pathlib.Path)
    a = ap.parse_args()
    here = pathlib.Path.cwd()
    if a.cmd == "tree":
        tree = clean_tree(here)
        if tree:
            print(tree)
        return 0 if tree else 1
    if a.cmd == "flake-show":
        kinds = flake_show(here)
        if kinds:
            print(kinds)
        return 0 if kinds else 1
    try:
        tops = read_toplevels(a.toplevels) if a.toplevels else {}
    except (OSError, UnicodeDecodeError) as e:
        say(f"not recorded: {e}")
        return 0
    put(here, a.tree, a.flake_kinds, tops)
    return 0


if __name__ == "__main__":
    sys.exit(main())
