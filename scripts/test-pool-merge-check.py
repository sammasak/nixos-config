#!/usr/bin/env python3
"""scripts/pool_merge_check.py's choice of checks from changed paths, and its migration numbering, without Nix: a docs
change runs nothing, a rule or dashboard change its own checks and no host, exec-pool its build and the pool's hosts,
flake.lock and any unmapped path every host (seeded: a rule change beside an unmapped path still evaluates every
host; two migrations on one number, and a gap, fail). Every evaluation takes the heavy lock, then the light one the
push hook's evaluation takes, and a build compiles under the heavy one alone. A slot's nix wrapper, from the module's
text with flock and nix stubbed: build --expr, --file and flake attributes evaluate under light and build outside it,
nix-build instantiates under light and builds outside it, and flake check runs under light."""

import importlib.util
import os
import pathlib
import re
import subprocess
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


# Placeholder names: the push hook runs every scripts/test-* that names a changed doc, and this one needs the gate probe.
check(got("notes.md", "docs/notes.md", "README-x.md") == set(), "docs and a top-level *.md: nothing")
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
check(got("scripts/test-x.py", "scripts/test-y.sh") == set(), "a test script: nothing, no host")
reads = [f"{f}: {l.strip()}" for f in sorted(HERE.parent.glob("[!.]*/**/*.nix")) if f.parts[len(HERE.parent.parts)] != "flake-modules"
         for l in f.read_text().splitlines() if "/scripts/test-" in l and not l.lstrip().startswith("#")]
check(reads == [], f"no host module reads a scripts/test-* file, so its change needs no host evaluation ({reads})")
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
tree = pathlib.Path("/t")
for kind, target in (("eval", "msi-ms7758"), ("build", "exec-pool"), ("check", "grafana-dashboards")):
    argv = pmc.command(pmc.Check(kind, target), tree)
    if kind == "eval":
        locks, evals_first = [argv[i + 2] for i, a in enumerate(argv) if a == "flock"], argv[argv.index("nix") + 1] == "eval"
    else:
        # bash -c BUILD $0 LIGHT ATTR: the light lock is the script's $1, taken inside the one heavy hold
        locks = [argv[2], argv[-2]] if argv[3:5] == ["bash", "-c"] and argv[5] == pmc.BUILD else []
        evals_first = pmc.BUILD.index('flock -o "$1" nix eval') < pmc.BUILD.index("nix build") and argv[-1].endswith(".drvPath")
    check(locks == [str(pmc.LOCK), str(pmc.LIGHT)] and evals_first,
          f"{kind} {target}: evaluated under the heavy lock, then the light one ({argv})")
check("WORK_LOCKS_HELD=1" in pmc.EVAL and pmc.BUILD.startswith("export WORK_LOCKS_HELD=1;"),
      "its nix runs marked as holding its locks, or a pool slot's nix waits on the light hold it is under")
check(pmc.LIGHT.name == "light-work.lock" and "light-work.lock" in (HERE.parent / "devenv.nix").read_text(),
      "the light lock is the one the push hook's nix flake show takes")


def lane(name: str, real: str, d: pathlib.Path) -> pathlib.Path:
    """A slot's `name` wrapper (modules/workers/execution-pool.nix) as bash, its flock, nix and lock file stubbed."""
    src = (HERE.parent / "modules/workers/execution-pool.nix").read_text()
    template = src.split("pkgs.writeShellScriptBin name ''\n", 1)[1].split("\n              ''\n", 1)[0]
    head = f'(lane "{name}" {real} \'\'\n'
    check(head in src, f"the module has a {name} lane")
    body = src.split(head, 1)[1].split("\n            '')\n", 1)[0] if head in src else ""
    text = template.replace("${text}", body).replace("${real}", "${nix}")
    for k, v in {"${pkgs.util-linux}/bin/flock": f"{d}/stub/flock", "/run/work-locks/light-work.lock": f"{d}/light",
                 "${config.nix.package}/bin/nix-instantiate": f"{d}/stub/nix-instantiate",
                 "${config.nix.package}/bin/nix-build": f"{d}/stub/nix-build", "${pkgs.coreutils}/bin/": "", "${pkgs.bash}/bin/bash": "bash",
                 "${nix}": f"{d}/stub/nix", "${name}": name, "''$": "$"}.items():
        text = text.replace(k, v)
    out = d / name
    out.write_text("#!/usr/bin/env bash\n" + text + "\n")
    out.chmod(0o755)
    return out


# each run of the stub nix as `argv locked|free`: an evaluation prints a drv, as nix eval --raw would
with tempfile.TemporaryDirectory() as tmp:
    d = pathlib.Path(tmp)
    (d / "light").touch()
    (d / "stub").mkdir()
    (d / "stub/flock").write_text('#!/usr/bin/env bash\nwhile [ "${1#-}" != "$1" ] || [ "$1" = 900 ] || [ "$1" = 75 ]; do shift; done\n'
                             'shift; IN_LOCK=locked exec "$@"\n')
    (d / "stub/nix").write_text(f'#!/usr/bin/env bash\necho "$* ${{IN_LOCK:-free}}" >>{d}/log\n'
                                '[ "$1" != eval ] || [[ $* == *fn.nix* ]] || echo /nix/store/x.drv^out\n')
    # nix-instantiate --add-root R: two roots, the second one's output bin, as the real one prints them
    (d / "stub/nix-instantiate").write_text(
        f'#!/usr/bin/env bash\necho "instantiate $* ${{IN_LOCK:-free}}" >>{d}/log\n'
        '[ "$1" = --add-root ] || exit 0\nln -s /nix/store/x.drv "$2"; ln -s /nix/store/y.drv "$2-2"; echo "$2"; echo "$2-2!bin"\n')
    (d / "stub/nix-build").write_text(f'#!/usr/bin/env bash\necho "nix-build $* ${{IN_LOCK:-free}}" >>{d}/log\n'
                                      'echo /nix/store/x-out\nexit "${NB_RC:-0}"\n')
    for f in ("flock", "nix", "nix-instantiate", "nix-build"):
        (d / "stub" / f).chmod(0o755)
    wrappers = {"nix": lane("nix", "nix", d), "nix-instantiate": lane("nix-instantiate", '"${config.nix.package}/bin/nix-instantiate"', d),
                "nix-build": lane("nix-build", '"${config.nix.package}/bin/nix-build"', d)}
    (d / "tmp").mkdir()
    env = {k: v for k, v in os.environ.items() if k != "WORK_LOCKS_HELD"} | {"TMPDIR": str(d / "tmp")}

    def runs(*argv: str, exe: str = "nix", **extra: str) -> list[str]:
        (d / "log").write_text("")
        subprocess.run([str(wrappers[exe]), *argv], env=env | extra, check=False, stdout=subprocess.DEVNULL)
        return [re.sub(rf"{re.escape(str(d / 'tmp'))}/[^ ]+/drv", "ROOT", line) for line in (d / "log").read_text().splitlines()]

    probe = "(import ./scripts/gate-probe.nix { }).json"
    PICK = ('d: if builtins.isAttrs d && d.type or null == "derivation" then d.drvPath + "^" + builtins.concatStringsSep "," '
            '(if d.outputSpecified or false then [ d.outputName ] else d.meta.outputsToInstall or ')
    APPLY, FILE = PICK + '[ "out" ]) else ""', PICK + 'd.outputs or [ d.outputName ]) else ""'
    r = runs("build", "--impure", "--no-link", "--print-out-paths", "--expr", probe)
    check(r == [f"eval --impure --raw --expr {probe}", f"  --apply {FILE} locked", "build --impure --no-link --print-out-paths /nix/store/x.drv^out free"],
          f"a slot's nix build --expr evaluates its drvPath under the light lock and builds outside it ({r})")
    r = runs("build", "--no-link", ".#a", ".#b")
    check(r == [f"eval --raw .#a --apply {APPLY} locked", f"eval --raw .#b --apply {APPLY} locked", "build --no-link /nix/store/x.drv^out /nix/store/x.drv^out free"],
          f"each flake attribute likewise ({r})")
    r = runs("build", "--expr", "e", "a", "b")
    check(r == ["eval --raw --expr e", f" a --apply {FILE} locked", "eval --raw --expr e", f" b --apply {FILE} locked",
                "build /nix/store/x.drv^out /nix/store/x.drv^out free"],
          f"each attribute of an --expr evaluates under the lock, the build outside it ({r})")
    r = runs("build", "--no-link", "-f", "default.nix", "--arg", "x", "1", "hello")
    check(r == [f"eval --arg x 1 --raw --file default.nix hello --apply {FILE} locked", "build --no-link /nix/store/x.drv^out free"],
          f"an attribute of a --file likewise, its --arg on the evaluation only ({r})")
    r = runs("build", "--file", "default.nix")
    check(r == [f"eval --raw --file default.nix  --apply {FILE} locked", "build /nix/store/x.drv^out free"],
          f"a --file without an attribute: the file's value ({r})")
    r = runs("build", "-f", "fn.nix", "--arg", "x", "1")
    check(r == [f"eval --arg x 1 --raw --file fn.nix  --apply {FILE} locked", "build -f fn.nix --arg x 1 free"],
          f"a value that is no one derivation (a function to call) is built whole, as nix build would ({r})")
    r = runs("build", "--no-link", "-o")
    check(r == ["build --no-link -o free"], f"a flag missing its value is passed through whole, for nix to refuse ({r})")
    r = runs("build", "--file", "default.nix", ".#x")
    check(r == ["build --file default.nix .#x free"], f"a flake reference with --file is passed through whole ({r})")
    r = runs("flake", "check", "--no-build")
    check(r == ["flake check --no-build locked"], f"nix flake check runs wholly under the lock ({r})")
    r = runs("-A", "x", "-o", "res", "--arg", "a", "1", "--no-out-link", "default.nix", exe="nix-build")
    check(r == ["instantiate --add-root ROOT -A x --arg a 1 default.nix locked", "nix-build -o res --no-out-link /nix/store/x.drv /nix/store/y.drv!bin free"],
          f"nix-build instantiates under the lock and builds the rooted drvs outside it, out-link flags on the build ({r})")
    check(list((d / "tmp").iterdir()) == [], "nix-build removes its roots once built")
    b = subprocess.run([str(wrappers["nix-build"]), "default.nix"], env=env | {"NB_RC": "3"}, capture_output=True, text=True, check=False)
    check(b.returncode == 3 and b.stdout == "/nix/store/x-out\n", f"nix-build's exit status and stdout are the build's ({b.returncode}, {b.stdout!r})")
    (d / "x.drv").symlink_to("/nix/store/x.drv")
    r = runs(str(d / "x.drv"), exe="nix-build")
    check(r == [f"nix-build {d}/x.drv free"], f"nix-build of a drv is passed through whole ({r})")
    r = runs("default.nix", "-A", exe="nix-build")
    check(r == ["nix-build default.nix -A free"], f"nix-build with a flag missing its value is passed through whole ({r})")
    r = runs("--check", "default.nix", exe="nix-build")
    check(r == ["nix-build --check default.nix free"], f"nix-build with another flag is passed through whole ({r})")
    r = runs("--option", "cores", "1", "eval", "--raw", ".#x")
    check(r == ["--option cores 1 eval --raw .#x locked"], f"a global option before eval: still under the lock ({r})")
    r = runs("--option", "cores", "1", "build", ".#x")
    check(r == [f"eval --option cores 1 --raw .#x --apply {APPLY} locked", "build --option cores 1 /nix/store/x.drv^out free"],
          f"a global option before build goes to its evaluation and its build ({r})")
    r = runs("-A", "x", "default.nix", exe="nix-instantiate")
    check(r == ["instantiate -A x default.nix locked"], f"nix-instantiate runs under the lock ({r})")
    r = runs("build", ".#")
    check(r == ["build .# free"], f"the default package (an empty fragment) is passed through whole ({r})")
    r = runs("store", "gc")
    check(r == ["store gc free"], f"another subcommand runs unlocked ({r})")

repo = HERE.parent / "pkgs/exec-pool/migrations"
check(pmc.migrations_problem(repo) is None, f"this tree's exec-pool migrations ({pmc.migrations_problem(repo)})")

sys.exit(1 if failures else 0)
