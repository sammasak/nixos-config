#!/usr/bin/env python3
"""scripts/pool_merge_check.py's choice of checks from changed paths, and its migration numbering, without Nix: a docs
change runs nothing, a rule or dashboard change its own checks and no host, exec-pool its build and the pool's hosts,
flake.lock and any unmapped path every host (seeded: a rule change beside an unmapped path still evaluates every
host; two migrations on one number, and a gap, fail)."""

import importlib.util
import pathlib
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("pool_merge_check", HERE / "pool_merge_check.py")
assert spec and spec.loader
pmc = importlib.util.module_from_spec(spec)
# dataclasses reads the module back from sys.modules
sys.modules[spec.name] = pmc
spec.loader.exec_module(pmc)

HOSTS = ["acer-swift", "asus-b460m", "black-pi", "lenovo", "msi-ms7758", "naked-pi"]
PKGDIRS = ["exec-pool", "scheduled-gate", "platform-record"]
failures = 0


def check(ok: bool, what: str) -> None:
    global failures
    print(f"{'PASS' if ok else 'FAIL'}: {what}")
    failures += not ok


def got(*paths: str) -> set[tuple[str, str]]:
    return {(c.kind, c.target) for c in pmc.plan(list(paths), HOSTS, PKGDIRS)}


def evals(s: set[tuple[str, str]]) -> set[str]:
    return {t for k, t in s if k == "eval"}


check(got("goals.md", "docs/shipping.md", "CLAUDE.md") == set(), "docs and goals.md: nothing")
check(got("docs/sub/x.md") == set(), "a nested doc under docs/: nothing")
check(evals(got("hosts/lenovo-21CB001PMX/notes.md")) == set(HOSTS), "a *.md outside docs/ and the top level is not a doc")
r = got("modules/homelab/monitoring/rules/exec-pool.yaml")
check(r == {("check", c) for c in pmc.RULE_CHECKS}, f"a rule file: the rule checks, no host ({sorted(r)})")
check(("check", "grafana-dashboards") in r, "a rule file: grafana-dashboards, which reads the names its rules select")
check(evals(got("modules/homelab/monitoring/rules/homelab.nix")) == set(HOSTS), "the rules' Nix renderer: every host")
d = got("modules/homelab/monitoring/dashboards/shipping.json")
check(d == {("check", c) for c in pmc.DASHBOARD_CHECKS} | {("eval", "black-pi")},
      f"a dashboard: the dashboard checks and black-pi, whose evaluation asserts its datasources ({sorted(d)})")
e = got("pkgs/exec-pool/src/queue.rs")
check(e == {("build", "exec-pool"), ("eval", "acer-swift"), ("eval", "msi-ms7758")},
      f"exec-pool: its build and the pool's hosts ({sorted(e)})")
m = got("pkgs/exec-pool/migrations/0023_x.up.sql")
check(("migrations", "pkgs/exec-pool/migrations") in m, "an exec-pool migration: its numbering too")
f = got("flake.lock")
check(evals(f) == set(HOSTS) and ("script", "scripts/test-deploy-recipes.py") in f,
      "flake.lock: every host and the private-input test")
for path in ("flake.nix", "flake-modules/pkgs-dir.nix", "scripts/flake-output-kinds.json"):
    k = got(path)
    check(evals(k) == set(HOSTS) and ("script", "scripts/test-flake-output-kinds.py") in k,
          f"{path}: every host and the output-kinds test")
s = got("pkgs/scheduled-gate/scheduled_gate.py")
check(("build", "scheduled-gate") in s and evals(s) == set(HOSTS), "another package: its build and every host")
check(evals(got("pkgs/patches/x.patch")) == set(HOSTS) and not any(k == "build" for k, _ in got("pkgs/patches/x.patch")),
      "a pkgs dir with no package of its own: every host, no build")
mixed = got("modules/homelab/monitoring/rules/homelab.yaml", "modules/core/fleet.nix")
check(evals(mixed) == set(HOSTS) and ("check", "monitoring-rules-tests") in mixed,
      "seeded: a rule change beside an unmapped path still evaluates every host")

with tempfile.TemporaryDirectory() as t:
    d = pathlib.Path(t)
    for n in ("0001_a.up.sql", "0001_a.down.sql", "0002_b.up.sql"):
        (d / n).touch()
    check(pmc.migrations_problem(d) is None, "migrations 0001 and 0002, one name each: no problem")
    (d / "0002_c.up.sql").touch()
    p = pmc.migrations_problem(d)
    check(p is not None and "0002 b and c" in p, f"seeded: two migrations on 0002 fail ({p})")
    (d / "0002_c.up.sql").unlink()
    (d / "0004_d.up.sql").touch()
    p = pmc.migrations_problem(d)
    check(p is not None and "0003" in p, f"seeded: a gap at 0003 fails ({p})")
repo = HERE.parent / "pkgs/exec-pool/migrations"
check(pmc.migrations_problem(repo) is None, f"this tree's exec-pool migrations ({pmc.migrations_problem(repo)})")

sys.exit(1 if failures else 0)
