#!/usr/bin/env python3
"""scripts/pool_merge_check.py's choice of checks from changed paths, and its migration numbering, without Nix: a docs
change runs nothing, a rule or dashboard change its own checks and no host, exec-pool its build and the pool's hosts,
scripts/, modules/workers/ and metrics/records.json the guest-records test, modules/workers/ also execution-pool-vm's
evaluation, flake.lock and any unmapped path every host, and a path that feeds a flake output the push hook's nix flake
show of the merge (seeded: a merge whose flake show fails fails; a rule change beside an unmapped path still evaluates every
host; two migrations on one number, and a gap, fail). Every evaluation takes the heavy lock, then the light one the
push hook's evaluation takes, and a build compiles under the heavy one alone; a step's record carries its wait for them
apart from its run (seeded: a held light lock). A slot's nix wrapper, from the module's text with nix and the record
stubbed: build --expr, --file and flake attributes evaluate under light and build outside it, nix-build instantiates
under light and builds outside it, and flake check runs under light; the command never inherits the lock, and each hold
is one lock record of its wait apart from its hold, in the spool the host ships whatever the caller's HOME (seeded: a
held light lock); it waits out a running scheduled gate for as long as the gate's unit may run, then gives up with rc 75
(seeded, the wait shortened). A slot's devenv warms its shell up under light only while no stamp matches what its cache
keys on: the files its last evaluation read, the env vars it read and the db itself, the same before and after the
warm-up (seeded: an unstamped checkout, a changed devenv.nix or imported file, a changed HOME or read env var, a
recreated or deleted db, a file edited during the warm-up, a failed warm-up). A slot's cargo has no lane and
CARGO_BUILD_JOBS from its reserve. The eval record (scripts/eval_record.py): a host evaluation and the flake show
recorded for the merge's tree under this nix are skipped, said and recorded as cached, and each that passes is recorded
(seeded: NIXOS_EVAL_RECORD=0, another nix, another tree, a corrupt record, a dirty checkout, a failed evaluation)."""

import contextlib
import importlib.util
import io
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import time
import types

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
check(e == {("build", "exec-pool"), ("eval", "acer-swift"), ("eval", "msi-ms7758"), ("show", "nixos-push-eval")},
      f"exec-pool: its build, the pool's hosts and the flake show ({sorted(e)})")
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
show = ("show", "nixos-push-eval")
for path in ("flake-modules/runtime-host-vm-test.nix", "flake.nix", "flake.lock", "tests/execution-pool-vm.nix",
             "pkgs/exec-pool/src/queue.rs", "modules/workers/execution-pool.nix", "templates/rust/flake.nix"):
    check(show in got(path), f"{path}: the push hook's nix flake show on the merge, where two clean branches can clash")
for paths in (("docs/x.md", "x.md"), ("scripts/test-x.py",), ("hosts/lenovo-21CB001PMX/configuration.nix",),
              ("modules/homelab/monitoring/rules/exec-pool.yaml",)):
    check(show not in got(*paths), f"{', '.join(paths)}: no flake show (docs, a test script, a host's evaluation covers it)")
reads = [f"{f}: {l.strip()}" for f in sorted(HERE.parent.glob("[!.]*/**/*.nix")) if f.parts[len(HERE.parent.parts)] != "flake-modules"
         for l in f.read_text().splitlines() if "/scripts/test-" in l and not l.lstrip().startswith("#")]
check(reads == [], f"no host module reads a scripts/test-* file, so its change needs no host evaluation ({reads})")
g = ("script", "scripts/test-guest-records.py")
for path in ("scripts/local-lane.py", "modules/workers/default.nix", "metrics/records.json"):
    check(g in got(path), f"{path}: the guest-records test, which holds a guest's record kinds to records.json")
check(g not in got("scripts/test-guest-records.py"), "a test script still maps to nothing")
w = got("modules/workers/execution-pool.nix")
check(("evalcheck", "execution-pool-vm") in w and ("check", "execution-pool-vm") not in w,
      "modules/workers/: execution-pool-vm's evaluation, no build")
check(not any(k == "evalcheck" for k, _ in got("modules/core/fleet.nix")), "another module: no execution-pool-vm evaluation")
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
sh = pmc.command(pmc.Check("show", "nixos-push-eval"), tree) or []
check(sh[sh.index("nix"):] == ["nix", "flake", "show", "--json", "--all-systems", "--no-write-lock-file", "/t"]
      and {"WORK_LOCKS_HELD=1", "GC_FREE_SPACE_DIVISOR=16"} <= set(sh[sh.index("env"):sh.index("nix")]),
      f"show: the push hook's nix flake show of the merge ({sh})")
a = (pmc.command(pmc.Check("evalcheck", "execution-pool-vm"), tree) or [""])[-1]
check(a == "/t#checks.x86_64-linux.execution-pool-vm.drvPath", f"evalcheck: the check's drvPath, nothing built ({a})")
check("WORK_LOCKS_HELD=1" in pmc.EVAL and "WORK_LOCKS_HELD=1" in pmc.BUILD,
      "its nix runs marked as holding its locks, or a pool slot's nix waits on the light hold it is under")

# each nix process with the locks it runs under: a stub nix that tries both (held, or free) and names an inherited one
with tempfile.TemporaryDirectory() as tmp:
    d = pathlib.Path(tmp)
    (d / "bin").mkdir()
    heavy, light = d / "heavy", d / "light"
    heavy.touch(), light.touch()
    (d / "bin/nix").write_text(
        "#!/usr/bin/env bash\nst() { flock -n \"$1\" true && echo free || echo held; }\n"
        f'inh=; for f in /proc/self/fd/*; do case $(readlink "$f") in {heavy} | {light}) inh=inherited ;; esac; done\n'
        f'echo "$1 heavy=$(st {heavy}) light=$(st {light}) $WORK_LOCKS_HELD $inh" >>{d}/log\n'
        '[ "$1" != eval ] || echo /nix/store/x.drv\n')
    (d / "bin/nix").chmod(0o755)
    saved = (os.environ["PATH"], pmc.LOCK, pmc.LIGHT)
    os.environ["PATH"] = f"{d / 'bin'}:{os.environ['PATH']}"
    pmc.LOCK, pmc.LIGHT = heavy, light
    try:
        for kind, target in (("eval", "msi-ms7758"), ("evalcheck", "execution-pool-vm"), ("show", "nixos-push-eval"),
                             ("build", "exec-pool"), ("check", "grafana-dashboards")):
            (d / "log").write_text("")
            ok, waited, _ = pmc.run(pmc.Check(kind, target), d)
            r = (d / "log").read_text().splitlines()
            first = "flake" if kind == "show" else "eval"
            want = [f"{first} heavy=held light=held 1 "] + (["build heavy=held light=free 1 "] if kind in ("build", "check") else [])
            check(ok and waited < 1 and r == want,
                  f"{kind} {target}: evaluated under the heavy lock, then the light one, neither inherited"
                  f"{', built under the heavy one alone' if len(want) > 1 else ''} ({r}, {waited:.1f} s waited)")
        holder = subprocess.Popen(["flock", str(light), "sleep", "2"])
        while subprocess.run(["flock", "-n", str(light), "true"], check=False).returncode == 0:
            time.sleep(0.05)
        ok, waited, _ = pmc.run(pmc.Check("eval", "lenovo"), d)
        holder.wait()
        check(ok and 1.2 <= waited < 5, f"seeded: a held light lock is measured as the step's wait ({waited:.1f} s)")
    finally:
        os.environ["PATH"], pmc.LOCK, pmc.LIGHT = saved
check(pmc.LIGHT.name == "light-work.lock" and "light-work.lock" in (HERE.parent / "devenv.nix").read_text(),
      "the light lock is the one the push hook's nix flake show takes")


def lane(name: str, real: str, d: pathlib.Path, exe: str = "${nix}") -> pathlib.Path:
    """A slot's `name` wrapper (modules/workers/execution-pool.nix) as bash, its nix, record and lock files stubbed."""
    src = (HERE.parent / "modules/workers/execution-pool.nix").read_text()
    template = src.split("pkgs.writeShellScriptBin name ''\n", 1)[1].split("\n              ''\n", 1)[0]
    head = f'(lane "{name}" {real} \'\'\n'
    check(head in src, f"the module has a {name} lane")
    body = src.split(head, 1)[1].split("\n            '')\n", 1)[0] if head in src else ""
    text = template.replace("${text}", body).replace("${real}", exe)
    for k, v in {"${pkgs.util-linux}/bin/flock": "flock", "${lib.getExe record}": f"{d}/stub/record", "${spool}": f"{d}/spool", "/run/work-locks/light-work.lock": f"{d}/light", "/run/work-locks/scheduled-gate.lock": f"{d}/gate",
                 "${config.nix.package}/bin/nix-instantiate": f"{d}/stub/nix-instantiate",
                 "${config.nix.package}/bin/nix-build": f"{d}/stub/nix-build", "${pkgs.coreutils}/bin/": "", "${pkgs.bash}/bin/bash": "bash",
                 "${nix}": f"{d}/stub/nix", "${devenv}": f"{d}/stub/devenv", "${gateWait}": "3", "${name}": name, "''$": "$"}.items():
        text = text.replace(k, v)
    out = d / name
    out.write_text("#!/usr/bin/env bash\n" + text + "\n")
    out.chmod(0o755)
    return out


# A slot's cargo (#827): in a devenv shell cargo is the profile's, which a PATH lane misses, so the cap is an environment
# variable every cargo reads (a login's, and the manager's DefaultEnvironment, which the runner's systemd-run steps get), and no cargo
# subcommand (--version, metadata or a compile) waits on a lock.
src = (HERE.parent / "modules/workers/execution-pool.nix").read_text()
check('(lane "cargo"' not in src and not re.search(r"\bcargo\b", src.split("(lane ", 1)[1].split("# Not a cargo lane", 1)[0]),
      "no cargo lane: cargo --version, cargo metadata and a compile wait on no lock")
cap = re.search(r"cargoJobs = toString \(\s*lib\.max 1 \(dev\.instances\.\$\{devEnvironment\.name\}\.memory\.reserved / 1073741824\)\s*\);", src)
check(cap is not None and "environment.sessionVariables.CARGO_BUILD_JOBS = cargoJobs;" in src
      and 'systemd.settings.Manager.DefaultEnvironment = "CARGO_BUILD_JOBS=${cargoJobs}";' in src,
      "a slot's CARGO_BUILD_JOBS, a job per GiB of its reserve and at least one, for logins and the runner's systemd-run steps")

# each run of the stub nix as `argv locked|free`: an evaluation prints a drv, as nix eval --raw would
with tempfile.TemporaryDirectory() as tmp:
    d = pathlib.Path(tmp)
    (d / "light").touch()
    (d / "stub").mkdir()
    # both locks real ones, their holder this test or the wrapper: a stub reports the light one locked when it cannot take
    # it, and inherited when it got the wrapper's descriptor
    (d / "stub/state").write_text(f'#!/usr/bin/env bash\nfor f in /proc/self/fd/*; do [ "$(readlink "$f")" != {d}/light ] || {{ echo inherited; exit; }}; done\n'
                                  f'flock -n {d}/light true && echo free || echo locked\n')
    (d / "stub/nix").write_text(f'#!/usr/bin/env bash\necho "$* $({d}/stub/state)" >>{d}/log\n'
                                '[ "$1" != eval ] || [[ $* == *fn.nix* ]] || echo /nix/store/x.drv^out\nexit "${NIX_RC:-0}"\n')
    # nix-instantiate --add-root R: two roots, the second one's output bin, as the real one prints them
    (d / "stub/nix-instantiate").write_text(
        f'#!/usr/bin/env bash\necho "instantiate $* $({d}/stub/state)" >>{d}/log\n'
        '[ "$1" = --add-root ] || exit 0\nln -s /nix/store/x.drv "$2"; ln -s /nix/store/y.drv "$2-2"; echo "$2"; echo "$2-2!bin"\n')
    (d / "stub/nix-build").write_text(f'#!/usr/bin/env bash\necho "nix-build $* $({d}/stub/state)" >>{d}/log\n'
                                      'echo /nix/store/x-out\nexit "${NB_RC:-0}"\n')
    # the spool the host ships, whatever HOME the caller has
    (d / "stub/record").write_text(f'#!/usr/bin/env bash\n[ "$PLATFORM_RECORD_SPOOL" = {d}/spool ] || exit 0\n'
                                   f'echo "$PLATFORM_RECORD_SHIPPER $*" >>{d}/records\n')
    for f in ("state", "nix", "nix-instantiate", "nix-build", "record"):
        (d / "stub" / f).chmod(0o755)
    wrappers = {"nix": lane("nix", "nix", d), "nix-instantiate": lane("nix-instantiate", '"${config.nix.package}/bin/nix-instantiate"', d),
                "nix-build": lane("nix-build", '"${config.nix.package}/bin/nix-build"', d)}
    (d / "tmp").mkdir()
    # a runner step's HOME is its attempt's, not the guest user's
    env = {k: v for k, v in os.environ.items() if k != "WORK_LOCKS_HELD"} | {"TMPDIR": str(d / "tmp"), "HOME": str(d / "tmp")}

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

    (d / "gate").touch()
    w = subprocess.run([str(wrappers["nix"]), "eval", "--raw", ".#x"], env=env, capture_output=True, text=True, check=False)
    r = (d / "log").read_text().splitlines()[-1:]
    check(r == ["eval --raw .#x locked"] and "scheduled gate" not in w.stderr,
          f"no scheduled gate: a slot's evaluation takes the light lock without waiting ({r}, {w.stderr.strip()!r})")
    holder = subprocess.Popen(["flock", str(d / "gate"), "sleep", "2"])
    while subprocess.run(["flock", "-n", str(d / "gate"), "true"], check=False).returncode == 0:
        time.sleep(0.05)
    (d / "log").write_text("")
    start = time.monotonic()
    w = subprocess.run([str(wrappers["nix"]), "eval", "--raw", ".#x"], env=env, capture_output=True, text=True, check=False)
    waited = time.monotonic() - start
    holder.wait()
    check(waited >= 1.2 and "waiting for the scheduled gate" in w.stderr and (d / "log").read_text().splitlines() == ["eval --raw .#x locked"],
          f"while the scheduled gate holds its lock a slot's evaluation waits it out, saying so ({waited:.1f} s, {w.stderr.strip()!r})")
    rec = (d / "records").read_text().splitlines()[-1:]
    check(rec and re.fullmatch(r"host lock lane=light class=nix-eval wait_seconds=[123] seconds=[01] rc=0", rec[0]) is not None,
          f"its lock record counts the gate's wait as the hold's, the host shipping it ({rec})")
    holder = subprocess.Popen(["flock", str(d / "gate"), "sleep", "6"])
    while subprocess.run(["flock", "-n", str(d / "gate"), "true"], check=False).returncode == 0:
        time.sleep(0.05)
    (d / "log").write_text(""), (d / "records").write_text("")
    w = subprocess.run([str(wrappers["nix"]), "eval", "--raw", ".#x"], env=env, capture_output=True, text=True, check=False)
    holder.kill(), holder.wait()
    rec = (d / "records").read_text().splitlines()
    check(w.returncode == 75 and "still holds" in w.stderr and "after 3 s" in w.stderr and (d / "log").read_text() == ""
          and len(rec) == 1 and re.fullmatch(r"host lock lane=light class=nix-eval wait_seconds=[345] seconds=[01] rc=75", rec[0]) is not None,
          f"seeded: a gate held past the wait (gateWait, 3 s here): rc 75, nothing run, the wait recorded ({w.returncode}, {w.stderr.strip()!r}, {rec})")
    (d / "gate").unlink()
    ep = (HERE.parent / "modules/workers/execution-pool.nix").read_text()
    gw = re.search(r"gateWait = toString \((\d+) \* 3600\);", ep)
    to = re.search(r'TimeoutStartSec = "(\d+)h";', (HERE.parent / "modules/homelab/scheduled-gate.nix").read_text())
    check(gw is not None and to is not None and gw.group(1) == to.group(1) and ep.count("${gateWait}") == 2,
          f"a slot waits out the scheduled gate for as long as the gate's unit may run ({gw and gw.group(0)}, {to and to.group(0)})")

    def recorded(*argv: str, **extra: str) -> tuple[int, list[str], list[str]]:
        (d / "records").write_text("")
        r = runs(*argv, **extra)
        rc = subprocess.run([str(wrappers["nix"]), *argv], env=env | extra, check=False, stdout=subprocess.DEVNULL).returncode
        return rc, r, (d / "records").read_text().splitlines()

    rc, r, rec = recorded("eval", "--raw", ".#x")
    check(rc == 0 and r == ["eval --raw .#x locked"] and len(rec) == 2
          and all(re.fullmatch(r"host lock lane=light class=nix-eval wait_seconds=[01] seconds=[01] rc=0", x) for x in rec),
          f"a free light lock: the command under it, never inheriting it, and one lock record per hold, shipped by the host ({r}, {rec})")
    rc, r, rec = recorded("flake", "show", "--json")
    check(re.fullmatch(r"host lock lane=light class=nix-flake-show wait_seconds=[01] seconds=[01] rc=0", rec[0] if rec else "") is not None,
          f"the class names the subcommand ({rec})")
    rc, r, rec = recorded("eval", ".#x", NIX_RC="3")
    check(rc == 3 and re.fullmatch(r"host lock lane=light class=nix-eval wait_seconds=[01] seconds=[01] rc=3", rec[0] if rec else "") is not None,
          f"the command's exit status is the wrapper's and its record's ({rc}, {rec})")
    rc, r, rec = recorded("build", "--no-link", ".#a")
    check(rc == 0 and re.fullmatch(r"host lock lane=light class=nix-build-eval wait_seconds=[01] seconds=[01] rc=0", rec[0] if rec else "") is not None
          and r[-1] == "build --no-link /nix/store/x.drv^out free",
          f"nix build: its evaluation's hold recorded, the record kept out of the drvs it picked ({r}, {rec})")
    holder = subprocess.Popen(["flock", str(d / "light"), "sleep", "2"])
    while subprocess.run(["flock", "-n", str(d / "light"), "true"], check=False).returncode == 0:
        time.sleep(0.05)
    (d / "records").write_text("")
    start = time.monotonic()
    w = subprocess.run([str(wrappers["nix-instantiate"]), "-A", "x", "default.nix"], env=env, capture_output=True, text=True, check=False)
    waited = time.monotonic() - start
    holder.wait()
    rec = (d / "records").read_text().splitlines()
    check(w.returncode == 0 and waited >= 1.2 and len(rec) == 1
          and re.fullmatch(r"host lock lane=light class=nix-instantiate wait_seconds=[123] seconds=[01] rc=0", rec[0]) is not None,
          f"seeded: a held light lock is waited for and recorded as the wait, not the hold ({waited:.1f} s, {rec})")

    # devenv's warm-up: the stub writes .devenv/input-paths.txt as devenv does, the files its evaluation read, and its
    # cache db with the env var names it read (eval_env_input), unless one is there; EDIT changes a listed file during it
    co = d / "checkout"
    (co / "sub").mkdir(parents=True)
    for f in ("devenv.nix", "devenv.lock", "devenv.yaml", "imported.nix"):
        (co / f).write_text("v1\n")
    reads = [co / f for f in ("devenv.nix", "devenv.lock", "devenv.yaml", "devenv.local.nix", "imported.nix")]
    db = co / ".devenv/nix-eval-cache.db"
    # the db as the stub sqlite3 reads it: the names of the env vars the evaluation read, one a line
    mkdb = "MY_EVAL_VAR\n"
    (d / "stub/names").write_text(mkdb)
    (d / "stub/devenv").write_text(
        f'#!/usr/bin/env bash\necho "devenv $* $({d}/stub/state)" >>{d}/log\n'
        f'[ "$*" = "shell -- true" ] || exit 0\nmkdir -p {co}/.devenv\n'
        f"printf '%s\\n' {' '.join(map(str, reads))} >{co}/.devenv/input-paths.txt\n"
        f'[ -e {db} ] || cp {d}/stub/names {db}\n'
        f'[ -z "${{EDIT:-}}" ] || echo edited >>{co}/imported.nix\n'
        'exit "${WARM_RC:-0}"\n')
    # sqlite3 -readonly DB QUERY: the names, as the CLI prints a one-column result (the query on a real db: acer, PR body)
    (d / "stub/sqlite3").write_text('#!/usr/bin/env bash\n[ "$1 $3" = "-readonly SELECT DISTINCT name FROM eval_env_input" ] && cat "$2"\n')
    for f in ("devenv", "sqlite3"):
        (d / "stub" / f).chmod(0o755)
    wrappers["devenv"] = lane("devenv", "devenv", d, f"{d}/stub/devenv")
    text = wrappers["devenv"].read_text()
    check("${pkgs.sqlite}/bin/sqlite3" in text, "the devenv lane reads devenv's db with sqlite3")
    wrappers["devenv"].write_text(text.replace("${pkgs.sqlite}/bin/sqlite3", f"{d}/stub/sqlite3"))

    def entered(cwd: pathlib.Path = co, **extra: str) -> tuple[list[str], bool]:
        (d / "log").write_text("")
        subprocess.run([str(wrappers["devenv"]), "shell", "--", "x"], cwd=cwd, env=env | extra, check=False, stdout=subprocess.DEVNULL)
        return (d / "log").read_text().splitlines(), (co / ".devenv/light-warm").exists()

    WARM, RUN = "devenv shell -- true locked", "devenv shell -- x free"
    r, stamped = entered()
    check(r == [WARM, RUN] and not stamped,
          f"an unstamped checkout with no input list: the warm-up under the light lock, then the shell outside it; no key "
          f"before it, so no stamp ({r})")
    r, stamped = entered()
    check(r == [WARM, RUN] and stamped, f"the next call: the same key before and after its warm-up, so a stamp ({r})")
    r, _ = entered()
    check(r == [RUN], f"a stamped checkout: no warm-up, no light hold ({r})")
    r, _ = entered(co / "sub")
    check(r == [RUN], f"from a subdirectory: devenv's root found, its stamp read ({r})")
    for what, act in (("a changed devenv.nix", lambda: (co / "devenv.nix").write_text("v2\n")),
                      ("a changed file devenv.nix imports (its input list)", lambda: (co / "imported.nix").write_text("v2\n")),
                      ("a local override created where none was", lambda: (co / "devenv.local.nix").write_text("{ }\n"))):
        act()
        r, _ = entered()
        r2, _ = entered()
        check(r == [WARM, RUN] and r2 == [RUN], f"seeded: {what} warms up again, and is stamped ({r}, {r2})")
    for what, extra in (("a HOME other than the last evaluation's", {"HOME": str(d)}),
                        ("an env var devenv's db says it read (MY_EVAL_VAR)", {"MY_EVAL_VAR": "1"}),
                        ("NIXPKGS_ALLOW_UNFREE, one this repo's cache holds", {"NIXPKGS_ALLOW_UNFREE": "1"})):
        r, _ = entered(**extra)
        r2, _ = entered(**extra)
        r3, _ = entered()
        check(r == [WARM, RUN] and r2 == [RUN] and r3 == [WARM, RUN], f"seeded: {what} warms up, and back again ({r}, {r2}, {r3})")
    entered()
    r, _ = entered(OTHER_VAR="1")
    check(r == [RUN], f"an env var devenv did not read keys nothing ({r})")
    fresh = co / ".devenv/new.db"
    fresh.write_text(mkdb)
    fresh.replace(db)
    r, _ = entered()
    check(r == [WARM, RUN], f"seeded: a recreated cache db (another inode) warms up again ({r})")
    entered()
    db.unlink()
    r, stamped = entered()
    check(r == [WARM, RUN], f"seeded: a deleted cache db warms up again ({r})")
    entered()
    (co / ".devenv/light-warm").unlink()
    r, stamped = entered(EDIT="1")
    check(r == [WARM, RUN] and not stamped, f"seeded: a listed file changed during the warm-up: no stamp ({r})")
    r, stamped = entered()
    check(r == [WARM, RUN] and stamped, f"so the next call warms up again, and stamps ({r})")
    (co / "devenv.lock").write_text("v3\n")
    (co / ".devenv/light-warm").unlink()
    r, stamped = entered(WARM_RC="1")
    check(r == [WARM, RUN] and not stamped, f"seeded: a failed warm-up writes no stamp ({r})")
    r, stamped = entered()
    check(r == [WARM, RUN] and stamped, f"so the next call warms up again, and stamps ({r})")
    (co / ".devenv/input-paths.txt").unlink()
    r, _ = entered()
    check(r == [WARM, RUN], f"seeded: no input list (a .devenv devenv never wrote) warms up ({r})")
    entered()
    (d / "records").write_text("")
    r, _ = entered()
    check(r == [RUN] and (d / "records").read_text() == "", f"a skipped warm-up writes no lock record ({r})")
    t0 = time.monotonic()
    for _ in range(20):
        subprocess.run([str(wrappers["devenv"]), "shell", "--", "x"], cwd=co, env=env, check=False, stdout=subprocess.DEVNULL)
    per = (time.monotonic() - t0) / 20 * 1000
    print(f"a stamped devenv call through the lane: {per:.0f} ms (sqlite3 stubbed)", flush=True)

DRV = "/nix/store/" + "a" * 32 + "-nixos-system-lenovo.drv"
TOP = "#nixosConfigurations.lenovo.config.system.build.toplevel.drvPath"


def eval_record_cases(d: pathlib.Path, repo: pathlib.Path, head: str, base: str, tree: str) -> list[tuple[bool, str]]:
    """check_tree on the head's own tree with this user's eval record (scripts/eval_record.py) seeded or not: what it
    runs (nix.log), each step's record, its output, and the record file afterwards."""
    state = d / "state/nixos-eval-records"
    rec = state / f"{tree}.json"
    (repo / ".git/nixos-qa-times").unlink(missing_ok=True)
    out: list[tuple[bool, str]] = []

    def go(**env: str) -> tuple[int, list[str], str, str]:
        for f in ("nix.log", "record.log"):
            (d / f).write_text("")
        for k in ("SHOW_RC", "EVAL_RC", "NIX_VERSION", "NIXOS_EVAL_RECORD"):
            os.environ.pop(k, None)
        os.environ.update(env)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = pmc.check_tree(repo, "b", head, base, head)
        return rc, (d / "nix.log").read_text().splitlines(), (d / "record.log").read_text(), buf.getvalue()

    def ran(log: list[str]) -> tuple[bool, bool]:
        return any(l.startswith("flake show") for l in log), any(l.endswith(TOP) for l in log)

    def seed(**fields: object) -> None:
        state.mkdir(parents=True, exist_ok=True)
        rec.write_text(json.dumps({"tree": tree, "nix": "nix (Nix) 2.0-test", **fields}))

    full = {"flake_show": "ok", "flake_kinds": '["checks","nixosConfigurations"]', "toplevel": {"lenovo": DRV}}
    shutil.rmtree(d / "state", ignore_errors=True)
    rc, log, steps, said = go()
    written = json.loads(rec.read_text()) if rec.exists() else {}
    out.append((rc == 0 and ran(log) == (True, True) and written == {"tree": tree, "nix": "nix (Nix) 2.0-test", **full},
                f"a miss: the flake show and the host evaluation run, and both go into the tree's record ({rc}, {log}, {written})"))
    rc, log, steps, said = go()
    cached = [l for l in steps.splitlines() if "result=cached" in l]
    out.append((rc == 0 and ran(log) == (False, False) and len(cached) == 2
                and any("step=pool-merge-show" in l for l in cached) and any("check=lenovo" in l for l in cached)
                and said.count("(eval record; NIXOS_EVAL_RECORD=0 runs it)") == 2 and DRV in said,
                f"a hit: neither runs again, each says why and records its step as cached ({rc}, {log}, {cached}, {said!r})"))
    rc, log, steps, said = go(NIXOS_EVAL_RECORD="0")
    out.append((rc == 0 and ran(log) == (True, True) and "result=cached" not in steps and rec.exists(),
                f"NIXOS_EVAL_RECORD=0: the record is not read, both run ({log})"))
    rc, log, steps, said = go(NIX_VERSION="nix (Nix) 9.9")
    out.append((rc == 0 and ran(log) == (True, True) and json.loads(rec.read_text())["nix"] == "nix (Nix) 9.9",
                f"a record of another nix is not used, and is replaced by this one's ({log})"))
    rec.unlink()
    other = "b" * 40
    (state / f"{other}.json").write_text(json.dumps({"tree": other, "nix": "nix (Nix) 2.0-test", **full}))
    seed(**{**full, "tree": other})
    rc, log, steps, said = go()
    out.append((rc == 0 and ran(log) == (True, True) and "result=cached" not in steps,
                f"seeded: records for another tree, one of them under this tree's name, are not used ({log})"))
    for bad in ("{not json", json.dumps({"tree": tree, "nix": "nix (Nix) 2.0-test", "toplevel": {"lenovo": "/tmp/x.drv"}}),
                json.dumps({"tree": tree, "nix": "nix (Nix) 2.0-test", "flake_show": "ok"}),
                json.dumps({"tree": tree, "nix": "nix (Nix) 2.0-test", "flake_show": "ok", "flake_kinds": "{"})):
        rec.write_text(bad)
        rc, log, steps, said = go()
        out.append((rc == 0 and ran(log) == (True, True),
                    f"seeded: a corrupt record ({bad[:40]}...) reads as a miss ({log})"))
    seed(flake_show="ok", flake_kinds="[]")
    (repo / "untracked.txt").write_text("x\n")
    rc, log, steps, said = go()
    (repo / "untracked.txt").unlink()
    out.append((rc == 0 and ran(log) == (True, True) and "toplevel" not in json.loads(rec.read_text()),
                f"seeded: a dirty checkout (an untracked file) neither reads its tree's record nor writes it ({log})"))
    # seventh-host-check's baselines run on its own (NIXOS_QA_TOPLEVELS unset), its own lines run here: this run's record
    # holds lenovo alone, as a pool-merge-check of a dashboard or exec-pool change holds some hosts
    seventh = (HERE / "seventh-host-check.py").read_text()
    pick = re.search(r'\n( *)(qa = os\.environ\.get\("NIXOS_QA_TOPLEVELS"\)\n *reused = [^\n]*)\n', seventh)
    out.append((pick is not None, "seventh-host-check picks its reused baselines in two lines (qa =, reused =)"))
    if pick:
        os.environ.pop("NIXOS_QA_TOPLEVELS", None)
        ns: dict = {"os": os, "pathlib": pathlib, "eval_record": pmc.eval_record, "ROOT": repo, "toplevels": dict}
        for real, want in ((["lenovo", "naked-pi"], {}), (["lenovo"], {"lenovo": DRV})):
            exec(textwrap.dedent(pick.group(2)), {**ns, "real": real}, got_ := {})
            out.append((got_.get("reused") == want,
                        f"seeded: seventh-host-check reuses the record's baselines only when it holds every real host "
                        f"({real}: {got_.get('reused')}); a partial one is not used, so its naked-pi check stays as before"))
    shutil.rmtree(d / "state")
    rc, log, steps, said = go(SHOW_RC="1", EVAL_RC="1")
    out.append((rc == 1 and ran(log) == (True, True) and not state.exists(),
                f"seeded: a failed flake show and host evaluation write no record ({rc}, {log})"))
    return out


# seeded: two branches that each evaluate merge into a tree whose flake show fails (#793 and #796, a duplicate definition)
with tempfile.TemporaryDirectory() as tmp:
    d = pathlib.Path(tmp)
    (d / "bin").mkdir()
    (d / "bin/flock").write_text('#!/usr/bin/env bash\nwhile [ "${1#-}" != "$1" ]; do shift; done\nshift; exec "$@"\n')
    (d / "bin/nix").write_text(f'#!/usr/bin/env bash\n[ "$1" != --version ] || {{ echo "${{NIX_VERSION:-nix (Nix) 2.0-test}}"; exit; }}\n'
                               f'echo "$*" >>{d}/nix.log\n'
                               '[ "$1" != flake ] || { echo \'{"checks": {}, "nixosConfigurations": {}}\'; exit "${SHOW_RC:-0}"; }\n'
                               f'[[ $* != *--apply* ]] || {{ echo lenovo; exit; }}\necho {DRV}\nexit "${{EVAL_RC:-0}}"\n')
    (d / "record.py").write_text(f"import sys\nopen({str(d / 'record.log')!r}, 'a').write(' '.join(sys.argv[1:]) + '\\n')\n")
    for f in ("flock", "nix"):
        (d / "bin" / f).chmod(0o755)
    repo = d / "repo"
    (repo / "tests").mkdir(parents=True)
    g = ["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@localhost"]
    subprocess.run([*g[:3], "init", "--quiet"], check=True)
    (repo / "tests/execution-pool-vm.nix").write_text("{ }\n")
    subprocess.run([*g, "add", "."], check=True)
    subprocess.run([*g, "commit", "--quiet", "-m", "base"], check=True)
    base = subprocess.run([*g, "rev-parse", "HEAD"], check=True, capture_output=True, text=True).stdout.strip()
    (repo / "tests/execution-pool-vm.nix").write_text("{ gh = 1; }\n")
    subprocess.run([*g, "commit", "--quiet", "-am", "the gh stub"], check=True)
    head = subprocess.run([*g, "rev-parse", "HEAD"], check=True, capture_output=True, text=True).stdout.strip()
    # main moved on: the merge's tree is not the head's, so the push hook's pass on the head does not cover it
    tree_ = subprocess.run([*g, "rev-parse", "HEAD^{tree}"], check=True, capture_output=True, text=True).stdout.strip()
    (repo / "main.txt").write_text("main\n")
    subprocess.run([*g, "add", "main.txt"], check=True)
    moved = subprocess.run([*g, "write-tree"], check=True, capture_output=True, text=True).stdout.strip()
    merge = subprocess.run([*g, "commit-tree", "-p", base, "-p", head, "-m", "merge", moved],
                           check=True, capture_output=True, text=True).stdout.strip()
    subprocess.run([*g, "reset", "--quiet", "--hard", head], check=True)
    saved = (os.getcwd(), os.environ["PATH"], pmc.RECORD, pmc.LOCK, pmc.LIGHT)
    os.chdir(repo)
    os.environ["PATH"] = f"{d / 'bin'}:{os.environ['PATH']}"
    os.environ["XDG_STATE_HOME"] = str(d / "state")
    os.environ.pop("NIXOS_EVAL_RECORD", None)
    pmc.RECORD, pmc.LOCK, pmc.LIGHT = d / "record.py", d / "heavy", d / "light"
    pmc.LOCK.touch(), pmc.LIGHT.touch()
    try:
        results = {}
        for rc in ("0", "1", "pushed", "moved"):
            os.environ["SHOW_RC"] = "0" if rc == "0" else "1"
            if rc == "pushed":
                (repo / ".git/nixos-qa-times").write_text(f"nixos-qa: full QA not run for {head}, owed to the scheduled gate on main\n")
            for f in ("nix.log", "record.log"):
                (d / f).write_text("")
            shutil.rmtree(d / "state", ignore_errors=True)
            results[rc] = (pmc.check_tree(repo, "b", head, base, merge if rc == "moved" else head),
                           (d / "nix.log").read_text(), (d / "record.log").read_text())
        # a step that took 32 s, 30 of them waiting for its locks: its record's seconds are its run alone
        run_, time_ = pmc.run, pmc.time
        clock = iter(range(0, 1000, 32))
        pmc.run = lambda c, tree: (True, 30.0, "")
        pmc.time = types.SimpleNamespace(monotonic=lambda: next(clock))
        (d / "record.log").write_text("")
        shutil.rmtree(d / "state", ignore_errors=True)
        pmc.check_tree(repo, "b", head, base, merge)
        waited = (d / "record.log").read_text()
        pmc.run, pmc.time = run_, time_
        recs = eval_record_cases(d, repo, head, base, tree_)
    finally:
        os.chdir(saved[0])
        os.environ["PATH"] = saved[1]
        for v in ("SHOW_RC", "EVAL_RC", "NIX_VERSION", "XDG_STATE_HOME", "NIXOS_EVAL_RECORD"):
            os.environ.pop(v, None)
        pmc.RECORD, pmc.LOCK, pmc.LIGHT = saved[2:]
    steps = [l for l in waited.splitlines() if "result=pass" in l]
    check(steps != [] and all(re.search(r" seconds=2 wait_seconds=30 ", l) for l in steps)
          and all(" wait_seconds=0 " in l for l in waited.splitlines() if "result=skipped" in l),
          f"a step's record has its lock wait apart from its run, a skipped one's 0 ({waited})")
    ok, bad = results["0"], results["1"]

    def shown(r: tuple[int, str, str], result: str) -> bool:
        return any(f"result={result}" in l for l in r[2].splitlines() if "step=pool-merge-show check=nixos-push-eval" in l)

    check(ok[0] == 0 and f"flake show --json --all-systems --no-write-lock-file {repo}" in ok[1] and shown(ok, "pass"),
          f"a tests/ change: its merge's flake show runs and records its own step ({ok})")
    check(bad[0] == 1 and shown(bad, "fail"),
          f"seeded: a merge whose flake show fails fails pool-merge-check, recorded as such ({bad})")
    pushed = results["pushed"]
    check(pushed[0] == 0 and "flake show" not in pushed[1] and shown(pushed, "skipped"),
          f"the merge is the head's own tree and this checkout's push hook passed it: no second flake show ({pushed})")
    moved_ = results["moved"]
    check(tree_ != moved and moved_[0] == 1 and "flake show" in moved_[1] and shown(moved_, "fail"),
          f"seeded: the push hook passed the head but main moved on: the merge's flake show still runs ({moved_})")
    for ok_, what in recs:
        check(ok_, what)

repo = HERE.parent / "pkgs/exec-pool/migrations"
check(pmc.migrations_problem(repo) is None, f"this tree's exec-pool migrations ({pmc.migrations_problem(repo)})")

sys.exit(1 if failures else 0)
