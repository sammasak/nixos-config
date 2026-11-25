#!/usr/bin/env python3
"""`just pool-merge-check BRANCH`: BRANCH merged with current origin/main (git merge-tree, a conflict exits 1) into a
throwaway worktree, then the checks its changed paths map to, each nix process under the heavy-work lock, one at a
time. Nothing is pushed.

A path maps to checks only where the gate's history shows what it can break (goals.md, "Check tuning"):
  docs/ and top-level *.md     nothing: the push hook's lints already ran on them
  monitoring rules (*.yaml)    the rule checks (promtool cases, annotations, routes, sleeping hosts, shipping rules)
  dashboards (*.json)          the dashboard checks
  pkgs/exec-pool/              its package build (crate tests, clippy, rustfmt) and the evaluation of the pool's hosts;
                               a migration also its numbering, one name per number and no gap
  flake.lock                   every host's evaluation and scripts/test-deploy-recipes.py (private inputs over ssh)
  any other path               every host's evaluation, as before: a NixOS assertion (sam.memory's budget among them)
                               runs only when a host's toplevel is evaluated
and each pkgs/<dir> with a changed file builds as `pkgsDir.<dir>` (flake-modules/pkgs-dir.nix). One nix process per
host: all six in one OOMs a pool slot's environments.slice, one alone peaks at about 4.2 GB (msi).

It prints each check run with its seconds, and each one skipped, and records both per check as gate-step records
(gate=pool-merge-check, step=pool-merge-<kind>, result=pass|fail|skipped; pkgs/platform-record), so the tally in
goals.md can be read back from Loki. No gate record: the platform dashboard's gate pass rate is the full gate's.

Usage: pool_merge_check.py BRANCH
       pool_merge_check.py --plan PATH...    the checks those changed paths map to, one per line (tests)"""

from __future__ import annotations

import argparse
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass

ROOT = pathlib.Path(__file__).resolve().parent.parent
RECORD = ROOT / "pkgs/platform-record/platform_record.py"
LOCK = pathlib.Path("/run/work-locks/heavy-work.lock")
SYSTEM = "x86_64-linux"

RULES = re.compile(r"modules/homelab/monitoring/rules/[^/]+\.ya?ml")
RULE_CHECKS = (
    "monitoring-rules-tests",
    "monitoring-alert-annotations",
    "monitoring-alert-routes",
    "monitoring-rules-sleeping-hosts",
    "shipping-rules",
)
DASHBOARDS = re.compile(r"modules/homelab/monitoring/dashboards/[^/]+\.json")
DASHBOARD_CHECKS = ("grafana-dashboards", "grafana-dashboard-removal")
# the hosts whose homelab.execPool runs the package (hosts/acer-swift/configuration.nix, hosts/msi-ms7758/exec-pool.nix)
POOL_HOSTS = ("acer-swift", "msi-ms7758")
MIGRATIONS = "pkgs/exec-pool/migrations/"
MIGRATION = re.compile(r"(\d{4})_([a-z0-9_]+)\.(up|down)\.sql")


@dataclass(frozen=True, order=True)
class Check:
    kind: str  # eval, build, check, script, migrations
    target: str


def is_doc(path: str) -> bool:
    return path.startswith("docs/") or ("/" not in path and path.endswith(".md"))


def plan(paths: list[str], hosts: list[str], pkgdirs: list[str]) -> list[Check]:
    """The checks the changed paths map to, sorted; every host's evaluation for a path with no narrower mapping."""
    want: set[Check] = set()
    every_host = False
    for p in paths:
        if is_doc(p):
            continue
        if RULES.fullmatch(p):
            want.update(Check("check", c) for c in RULE_CHECKS)
        elif DASHBOARDS.fullmatch(p):
            want.update(Check("check", c) for c in DASHBOARD_CHECKS)
        elif p.startswith("pkgs/exec-pool/"):
            want.add(Check("build", "exec-pool"))
            want.update(Check("eval", h) for h in POOL_HOSTS if h in hosts)
            if p.startswith(MIGRATIONS):
                want.add(Check("migrations", MIGRATIONS.rstrip("/")))
        elif p == "flake.lock":
            every_host = True
            want.add(Check("script", "scripts/test-deploy-recipes.py"))
        else:
            every_host = True
            m = re.match(r"pkgs/([^/]+)/", p)
            if m and m.group(1) in pkgdirs:
                want.add(Check("build", m.group(1)))
    if every_host:
        want.update(Check("eval", h) for h in hosts)
    return sorted(want)


def migrations_problem(directory: pathlib.Path) -> str | None:
    """Two parallel branches that each take the next number merge into one number with two names, or a gap."""
    names: dict[int, set[str]] = {}
    for f in directory.iterdir():
        m = MIGRATION.fullmatch(f.name)
        if not m:
            return f"{f.name}: not NNNN_name.up.sql or .down.sql"
        names.setdefault(int(m.group(1)), set()).add(m.group(2))
    clash = {n: sorted(v) for n, v in names.items() if len(v) > 1}
    if clash:
        return "one number, two migrations: " + "; ".join(f"{n:04d} {' and '.join(v)}" for n, v in sorted(clash.items()))
    gaps = sorted(set(range(1, max(names, default=0) + 1)) - set(names))
    return f"numbers missing: {', '.join(f'{n:04d}' for n in gaps)}" if gaps else None


def say(text: str, err: bool = False) -> None:
    print(f"pool-merge-check: {text}", file=sys.stderr if err else sys.stdout, flush=True)


def git(*args: str) -> str:
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout.strip()


def record(check: Check, seconds: int, result: str, sha: str, head: str) -> None:
    # a record is evidence: one that fails never fails the check (platform_record.py exits 0 for it)
    subprocess.run(
        [sys.executable, str(RECORD), "gate-step", "gate=pool-merge-check", f"step=pool-merge-{check.kind}",
         f"check={check.target}", f"seconds={seconds}", f"result={result}", f"sha={sha}", f"head={head}"],
        check=False,
    )


def command(check: Check, tree: pathlib.Path) -> list[str] | None:
    locked = ["flock", "-o", str(LOCK)]
    if check.kind == "eval":
        return [*locked, "nix", "eval", "--raw", f"{tree}#nixosConfigurations.{check.target}.config.system.build.toplevel.drvPath"]
    if check.kind == "build":
        return [*locked, "nix", "build", "--no-link", "-L", f"{tree}#pkgsDir.{check.target}"]
    if check.kind == "check":
        return [*locked, "nix", "build", "--no-link", "-L", f"{tree}#checks.{SYSTEM}.{check.target}"]
    if check.kind == "script":
        return [sys.executable, check.target]
    return None


def run(check: Check, tree: pathlib.Path) -> bool:
    argv = command(check, tree)
    if argv is None:
        problem = migrations_problem(tree / check.target)
        if problem:
            say(f"{check.target}: {problem}", err=True)
        return problem is None
    out = subprocess.run(argv, cwd=tree, stdout=subprocess.PIPE if check.kind == "eval" else None, text=True)
    if out.returncode == 0 and check.kind == "eval":
        say(f"{check.target} evaluates to {out.stdout.strip()}")
    return out.returncode == 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("branch", nargs="?")
    ap.add_argument("--plan", nargs="+", metavar="PATH")
    ap.add_argument("--hosts", default="lenovo acer-swift msi-ms7758 asus-b460m black-pi naked-pi")
    ap.add_argument("--pkgdirs", default="")
    a = ap.parse_args()
    if a.plan:
        for c in plan(a.plan, a.hosts.split(), a.pkgdirs.split()):
            print(f"{c.kind} {c.target}")
        return 0
    if not a.branch:
        ap.error("BRANCH or --plan")
    if not LOCK.exists():
        say(f"no {LOCK} on this host", err=True)
        return 1
    git("fetch", "--quiet", "origin", a.branch)
    head = git("rev-parse", "FETCH_HEAD")
    git("fetch", "--quiet", "origin", "main")
    main_ = git("rev-parse", "FETCH_HEAD")
    merged = subprocess.run(["git", "merge-tree", "--write-tree", main_, head], capture_output=True, text=True)
    if merged.returncode != 0:
        print(merged.stdout, file=sys.stderr)
        say(f"{a.branch} does not merge cleanly with origin/main", err=True)
        return 1
    commit = git("-c", "user.name=pool-merge-check", "-c", "user.email=pool-merge-check@localhost", "commit-tree",
                 "-p", main_, "-p", head, "-m", f"pool-merge-check {a.branch}", merged.stdout.split("\n")[0])
    tree = pathlib.Path(tempfile.mkdtemp())
    git("worktree", "add", "--quiet", "--detach", str(tree), commit)
    try:
        return check_tree(tree, a.branch, head, main_, commit)
    finally:
        git("worktree", "remove", "--force", str(tree))
        shutil.rmtree(tree, ignore_errors=True)


def check_tree(tree: pathlib.Path, branch: str, head: str, main_: str, commit: str) -> int:
    paths = git("diff", "--no-ext-diff", "--name-only", main_, commit).splitlines()
    nix = ["nix", "eval", "--raw", "--apply", "c: toString (builtins.attrNames c)"]
    hosts = subprocess.run([*nix, f"{tree}#nixosConfigurations"], check=True, capture_output=True, text=True).stdout.split()
    pkgdirs = subprocess.run([*nix, f"{tree}#pkgsDir"], check=True, capture_output=True, text=True).stdout.split()
    checks = plan(paths, hosts, pkgdirs)
    sha = commit[:12]
    skipped = [Check("eval", h) for h in hosts if Check("eval", h) not in checks]
    say(f"{len(paths)} changed path(s); {len(checks)} check(s) to run, {len(skipped)} host evaluation(s) skipped")
    for c in skipped:
        say(f"skipped: {c.kind} {c.target} (no changed path maps to it)")
        record(c, 0, "skipped", sha, head)
    times: list[tuple[Check, int, bool]] = []
    for c in checks:
        start = time.monotonic()
        ok = run(c, tree)
        secs = round(time.monotonic() - start)
        times.append((c, secs, ok))
        say(f"{'passed' if ok else 'FAILED'}: {c.kind} {c.target} ({secs} s)", err=not ok)
        record(c, secs, "pass" if ok else "fail", sha, head)
    failed = [c for c, _, ok in times if not ok]
    total = sum(s for _, s, _ in times)
    summary = ", ".join(f"{c.kind} {c.target} {s} s" for c, s, _ in times) or "none"
    say(f"ran {len(times)} in {total} s: {summary}")
    if failed:
        say(f"{branch} ({head}) merged with origin/main ({main_}) fails: "
            + ", ".join(f"{c.kind} {c.target}" for c in failed), err=True)
        return 1
    say(f"{branch} ({head}) merged with origin/main ({main_}) passes every check its paths map to")
    return 0


if __name__ == "__main__":
    sys.exit(main())
