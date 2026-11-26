#!/usr/bin/env python3
"""`just pool-merge-check BRANCH`: BRANCH merged with current origin/main (git merge-tree, a conflict exits 1) into a
throwaway worktree, then the checks its changed paths map to, each nix process under the heavy-work lock, one at a
time, and each evaluation under the light-work lock too. Nothing is pushed.

A path maps to checks only where the gate's history shows what it can break (goals.md, "Check tuning"):
  docs/ and top-level *.md     nothing: the push hook's lints already ran on them
  monitoring rules (*.yaml)    the rule checks (promtool cases, annotations, routes, sleeping hosts, shipping rules) and
                               grafana-dashboards, which finds each name a rule selects in what the fleet exports
  dashboards (*.json)          the dashboard checks and black-pi's evaluation (its datasource assertion)
  pkgs/exec-pool/              its package build (crate tests, clippy, rustfmt) and the evaluation of the pool's hosts;
                               a migration also its numbering, one name per number and no gap
  scripts/test-*               nothing: no host reads one, and the push hook and the full gate run it
  hosts/asus-b460m/, modules/homelab/ollama-host.nix, modules/homelab/paddock.nix, flake.lock
                               also scripts/test-ollama-gpu.py on its gate-probe section (asus as deployed and seeded):
                               an asus or Ollama change can break a seeded case the host's own evaluation never runs;
                               off asus its CUDA builds are deferred and pass unrecorded, so it proves the evaluation
  other scripts/, modules/workers/, metrics/records.json
                               also scripts/test-guest-records.py: a guest's record kinds are records.json's
  modules/workers/             also the execution-pool-vm check's evaluation, its drvPath only (no build)
  flake.lock                   every host's evaluation and scripts/test-deploy-recipes.py (private inputs over ssh)
  flake.nix, flake-modules/    every host's evaluation and scripts/test-flake-output-kinds.py: a new output kind fails
                               the gate's nixos-flake-check step only after every output evaluated
  any other path               every host's evaluation, as before: a NixOS assertion (sam.memory's budget among them)
                               runs only when a host's toplevel is evaluated
  flake.nix, flake.lock, flake-modules/, tests/, pkgs/, modules/workers/, templates/, apps/, lib/app-manifest/
                               also the push hook's `nix flake show` (nixos-push-eval) on the merge: what defines or
                               feeds a flake output (the VM tests read modules/workers/), where two branches that each
                               evaluate can merge into one that does not (a duplicate definition); skipped when the
                               merge is the branch's own tree and this checkout's push hook passed it for that head
and each pkgs/<dir> with a changed file builds as `pkgsDir.<dir>` (flake-modules/pkgs-dir.nix). One nix process per
host: all six in one OOMs a pool slot's environments.slice, one alone peaks at about 4.2 GB (msi). The light lane is
the push hook's `nix flake show` (devenv.nix pushEval, about 3.9 GiB): the slots share one slice, and on 25 Nov a host
evaluation here beside another slot's push evaluation filled acer's 7G twice. A build's derivation is evaluated under
both locks and built under the heavy one alone, so a push never waits on a compile.

It prints each check run with its seconds, and each one skipped, and records both per check as gate-step records
(gate=pool-merge-check, step=pool-merge-<kind>, result=pass|fail|skipped; pkgs/platform-record), so the tally in
goals.md can be read back from Loki: seconds= its run, wait_seconds= its waits for the locks, which this process takes
itself to time them. No gate record: the platform dashboard's gate pass rate is the full gate's.

Usage: pool_merge_check.py BRANCH
       pool_merge_check.py --plan PATH...    the checks those changed paths map to, one per line (tests)"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
from collections.abc import Iterator
from dataclasses import dataclass

ROOT = pathlib.Path(__file__).resolve().parent.parent
RECORD = ROOT / "pkgs/platform-record/platform_record.py"
LOCK = pathlib.Path("/run/work-locks/heavy-work.lock")
LIGHT = LOCK.with_name("light-work.lock")
SYSTEM = "x86_64-linux"

RULES = re.compile(r"modules/homelab/monitoring/rules/[^/]+\.ya?ml")
RULE_CHECKS = (
    "monitoring-rules-tests",
    "monitoring-alert-annotations",
    "monitoring-alert-routes",
    "monitoring-rules-sleeping-hosts",
    "shipping-rules",
    "grafana-dashboards",
)
DASHBOARDS = re.compile(r"modules/homelab/monitoring/dashboards/[^/]+\.json")
DASHBOARD_CHECKS = ("grafana-dashboards", "grafana-dashboard-removal")
# the hosts whose homelab.execPool runs the package (hosts/acer-swift/configuration.nix, hosts/msi-ms7758/exec-pool.nix)
POOL_HOSTS = ("acer-swift", "msi-ms7758")
MIGRATIONS = "pkgs/exec-pool/migrations/"
GUEST_RECORDS = "scripts/test-guest-records.py"
MIGRATION = re.compile(r"(\d{4})_([a-z0-9_]+)\.(up|down)\.sql")
# the paths flake-modules/ builds outputs from beyond a host's own modules, which a host evaluation already covers
FLAKE_FILES = ("flake.nix", "flake.lock")
FLAKE_DIRS = ("flake-modules/", "tests/", "pkgs/", "modules/workers/", "templates/", "apps/", "lib/app-manifest/")
SHOW = "nixos-push-eval"
# the paths whose change can move the test's gate-probe section; the section evaluates asus alone
OLLAMA_GPU = ("hosts/asus-b460m/", "modules/homelab/ollama-host.nix", "modules/homelab/paddock.nix", "flake.lock")
PROBE_SECTIONS = {"scripts/test-ollama-gpu.py": "ollama-gpu"}


@dataclass(frozen=True, order=True)
class Check:
    kind: str  # eval, evalcheck, show, build, check, script, probe, migrations
    target: str


def is_doc(path: str) -> bool:
    return path.startswith("docs/") or ("/" not in path and path.endswith(".md"))


def plan(paths: list[str], hosts: list[str], pkgdirs: list[str]) -> list[Check]:
    """The checks the changed paths map to, sorted; every host's evaluation for a path with no narrower mapping."""
    want: set[Check] = set()
    every_host = False
    for p in paths:
        if is_doc(p) or p.startswith("scripts/test-"):
            continue
        if p in FLAKE_FILES or p.startswith(FLAKE_DIRS):
            want.add(Check("show", SHOW))
        if p.startswith(("scripts/", "modules/workers/")) or p == "metrics/records.json":
            want.add(Check("script", GUEST_RECORDS))
        if p.startswith("modules/workers/"):
            want.add(Check("evalcheck", "execution-pool-vm"))
        if p.startswith(OLLAMA_GPU):
            want.add(Check("probe", "scripts/test-ollama-gpu.py"))
        if RULES.fullmatch(p):
            want.update(Check("check", c) for c in RULE_CHECKS)
        elif DASHBOARDS.fullmatch(p):
            want.update(Check("check", c) for c in DASHBOARD_CHECKS)
            # a panel's datasource uid is asserted only in black-pi's evaluation (modules/homelab/monitoring/grafana.nix)
            want.update(Check("eval", h) for h in ("black-pi",) if h in hosts)
        elif p.startswith("pkgs/exec-pool/"):
            want.add(Check("build", "exec-pool"))
            want.update(Check("eval", h) for h in POOL_HOSTS if h in hosts)
            if p.startswith(MIGRATIONS):
                want.add(Check("migrations", MIGRATIONS.rstrip("/")))
        elif p == "flake.nix" or p.startswith("flake-modules/") or p == "scripts/flake-output-kinds.json":
            every_host = True
            want.add(Check("script", "scripts/test-flake-output-kinds.py"))
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


def record(check: Check, seconds: int, wait: int, result: str, sha: str, head: str) -> None:
    # a record is evidence: one that fails never fails the check (platform_record.py exits 0 for it)
    subprocess.run(
        [sys.executable, str(RECORD), "gate-step", "gate=pool-merge-check", f"step=pool-merge-{check.kind}",
         f"check={check.target}", f"seconds={seconds}", f"wait_seconds={wait}", f"result={result}", f"sha={sha}",
         f"head={head}"],
        check=False,
    )


@contextlib.contextmanager
def held(lock: pathlib.Path, waits: list[float]) -> Iterator[None]:
    """The lock held by this process alone, as flock -o held it: the descriptor is not inherited (PEP 446), and a killed
    checker frees it. Read-only: a guest binds /run/work-locks read-only. The seconds waited go to waits."""
    fd = os.open(lock, os.O_RDONLY)
    try:
        start = time.monotonic()
        fcntl.flock(fd, fcntl.LOCK_EX)
        waits.append(time.monotonic() - start)
        yield
    finally:
        os.close(fd)


# WORK_LOCKS_HELD: a pool slot's nix (modules/workers/execution-pool.nix) would otherwise wait on this light hold, and
# take light for the build.
EVAL = ["env", "WORK_LOCKS_HELD=1", "nix", "eval", "--raw"]
# devenv.nix pushEval's command, import-from-derivation off as there (flake show's default); without the divisor it
# peaks above the 3.9 GiB the light lane is sized for
FLAKE_SHOW = ["env", "WORK_LOCKS_HELD=1", "GC_FREE_SPACE_DIVISOR=16", "nix", "flake", "show", "--json", "--all-systems",
              "--no-write-lock-file"]
BUILD = ["env", "WORK_LOCKS_HELD=1", "nix", "build", "--no-link", "-L"]
# a probe test's section: the divisor as devenv.nix's probe, which evaluates asus nine times for this one
PROBE = ["env", "WORK_LOCKS_HELD=1", "GC_FREE_SPACE_DIVISOR=16", "nix", "eval", "--raw", "--impure", "--expr"]


def gate_heavy(tree: pathlib.Path) -> str | None:
    """devenv.nix's gateHeavy, the pattern scripts/gate_defer.py defers a CUDA build by (it fails without one)."""
    m = re.search(r'^  gateHeavy = "([^"]+)";$', (tree / "devenv.nix").read_text(), re.M)
    return m.group(1) if m else None


def command(check: Check, tree: pathlib.Path) -> list[str] | None:
    """What runs under both locks: an eval's or evalcheck's evaluation, the flake show, a build's or check's drvPath
    (built afterwards under the heavy one alone), or a script, under none."""
    if check.kind == "eval":
        return [*EVAL, f"{tree}#nixosConfigurations.{check.target}.config.system.build.toplevel.drvPath"]
    if check.kind == "evalcheck":
        return [*EVAL, f"{tree}#checks.{SYSTEM}.{check.target}.drvPath"]
    if check.kind == "show":
        return [*FLAKE_SHOW, str(tree)]
    if check.kind in ("build", "check"):
        attr = f"pkgsDir.{check.target}" if check.kind == "build" else f"checks.{SYSTEM}.{check.target}"
        return [*EVAL, f"{tree}#{attr}.drvPath"]
    if check.kind == "script":
        return [sys.executable, check.target]
    if check.kind == "probe":
        section = PROBE_SECTIONS[check.target]
        return [*PROBE, f'(import ./scripts/gate-probe.nix {{ only = [ "{section}" ]; }}).json.drvPath']
    return None


EVALS = ("eval", "evalcheck")


def run(check: Check, tree: pathlib.Path) -> tuple[bool, float]:
    """Whether the check passed, and its seconds waiting for the locks."""
    argv = command(check, tree)
    if argv is None:
        problem = migrations_problem(tree / check.target)
        if problem:
            say(f"{check.target}: {problem}", err=True)
        return problem is None, 0.0
    if check.kind == "script":
        return subprocess.run(argv, cwd=tree, check=False).returncode == 0, 0.0
    waits: list[float] = []
    probe = check.kind == "probe"
    pattern = gate_heavy(tree) if probe else None
    if probe and not pattern:
        say(f"{tree / 'devenv.nix'}: no gateHeavy", err=True)
        return False, 0.0
    builds = check.kind in ("build", "check", "probe")
    stdout = subprocess.PIPE if check.kind in EVALS or builds else subprocess.DEVNULL if check.kind == "show" else None
    # heavy, then light: the push hook takes light alone, so the order never deadlocks. One heavy hold over a build's
    # evaluation and build: released between them, a long wait could let a GC delete the evaluated .drv
    with held(LOCK, waits):
        with held(LIGHT, waits):
            out = subprocess.run(argv, cwd=tree, stdout=stdout, text=True, check=False)
        if out.returncode == 0 and builds:
            out = subprocess.run([*BUILD, *(["--print-out-paths"] if probe else []), f"{out.stdout.strip()}^*"], cwd=tree,
                                 stdout=subprocess.PIPE if probe else None, text=True, check=False)
        # the test's own nix (a re-evaluation once a GC took the .drv files) is not marked as holding the light lock,
        # so a pool slot's nix takes it
        if out.returncode == 0 and probe:
            env = {k: v for k, v in os.environ.items() if k != "WORK_LOCKS_HELD"}
            out = subprocess.run([sys.executable, check.target], cwd=tree, check=False,
                                 env=env | {"GATE_PROBE": out.stdout.strip(), "GATE_HEAVY": pattern})
    if out.returncode == 0 and check.kind in EVALS:
        say(f"{check.target} evaluates to {out.stdout.strip()}")
    return out.returncode == 0, sum(waits)


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


def push_eval_passed(head: str, commit: str) -> bool:
    """The merge is the branch head's own tree and this checkout's push hook passed nixos-push-eval on that head: it
    writes `full QA not run for <head>` to nixos-qa-times only after that evaluation passed (devenv.nix)."""
    if git("rev-parse", f"{head}^{{tree}}") != git("rev-parse", f"{commit}^{{tree}}"):
        return False
    times = pathlib.Path(git("rev-parse", "--path-format=absolute", "--git-common-dir")) / "nixos-qa-times"
    try:
        return f"full QA not run for {head}," in times.read_text(errors="replace")
    except OSError:
        return False


def check_tree(tree: pathlib.Path, branch: str, head: str, main_: str, commit: str) -> int:
    paths = git("diff", "--no-ext-diff", "--name-only", main_, commit).splitlines()
    nix = [*EVAL, "--apply", "c: toString (builtins.attrNames c)"]
    with held(LOCK, []), held(LIGHT, []):
        hosts = subprocess.run([*nix, f"{tree}#nixosConfigurations"], check=True, capture_output=True,
                               text=True).stdout.split()
        pkgdirs = subprocess.run([*nix, f"{tree}#pkgsDir"], check=True, capture_output=True, text=True).stdout.split()
    checks = plan(paths, hosts, pkgdirs)
    sha = commit[:12]
    skipped = [Check("eval", h) for h in hosts if Check("eval", h) not in checks]
    show = Check("show", SHOW)
    if show in checks and push_eval_passed(head, commit):
        checks.remove(show)
        why = {show: f"the push hook passed it on {head}, whose tree this merge is"}
    else:
        why = {}
    skipped += [show] if show not in checks else []
    say(f"{len(paths)} changed path(s); {len(checks)} check(s) to run, {len(skipped)} skipped")
    for c in skipped:
        say(f"skipped: {c.kind} {c.target} ({why.get(c, 'no changed path maps to it')})")
        record(c, 0, 0, "skipped", sha, head)
    times: list[tuple[Check, int, bool]] = []
    for c in checks:
        start = time.monotonic()
        ok, waited = run(c, tree)
        secs, wait = round(time.monotonic() - start - waited), round(waited)
        times.append((c, secs, ok))
        say(f"{'passed' if ok else 'FAILED'}: {c.kind} {c.target} ({secs} s, after {wait} s waiting for the locks)",
            err=not ok)
        record(c, secs, wait, "pass" if ok else "fail", sha, head)
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
