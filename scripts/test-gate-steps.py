"""The gate's two step decisions (#502), taken from devenv.nix as written and run without Nix: nixos-flake-check's
`decide` (which check is built, left as unchanged since main, or left to its own host's gate) and nixos-qa's
`side_by_side` (steps run at once, each printed whole and recorded, the gate failing on any one of them)."""
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import textwrap

from gate_probe import check, finish

import gate_defer

ROOT = pathlib.Path(__file__).resolve().parent.parent


src = (ROOT / "devenv.nix").read_text()


def function(name):
    m = re.search(r"\n( *)" + name + r"\(\) \{\n.*?\n\1\}\n", src, re.S)
    if not m:
        sys.exit(f"FAIL (scripts/test-gate-steps.py): {name}() not found in devenv.nix")
    return textwrap.dedent(m.group(0)).replace("''${", "${")


# the heavy pattern is defined once, as gateHeavy, and interpolated into the flake check and the gpu test's GATE_HEAVY
gate_heavy = re.search(r'\n *gateHeavy = "([^"]*)";\n', src)
heavy = re.search(r"\n *heavy='\$\{gateHeavy\}'\n", src)
if not gate_heavy or not heavy:
    sys.exit("FAIL (scripts/test-gate-steps.py): gateHeavy, or the flake check's heavy='${gateHeavy}', not found in devenv.nix")
check("GATE_HEAVY='${gateHeavy}'" in src and "-cuda" not in src.replace(gate_heavy.group(0), ""),
      "the heavy pattern has one definition (gateHeavy): the flake check and ollama-gpu-test's GATE_HEAVY both read it")
DECIDE = f"heavy='{gate_heavy.group(1)}'\n" + function("decide")


def decide(here, check_name, todo, inputs="", cudahost="0"):
    r = subprocess.run(["bash", "-euo", "pipefail", "-c", DECIDE + '\ndecide "$@"', "decide", here, check_name, todo, inputs, cudahost],
                       capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else f"rc={r.returncode} {r.stderr.strip()}"


# what a dry-run of asus's deploy checks lists on acer: the CUDA Ollama is plain ollama-0.x by name, its inputs say CUDA
todo = "/nix/store/aaa-ollama-0.40.3.drv\n/nix/store/bbb-unit-ollama.service.drv"
cuda = "/nix/store/ccc-cuda13.4-cuda_cudart-13.4.92.drv\n/nix/store/ddd-nvidia-x11-595.104.02.drv\n/nix/store/eee-cmake.drv"
cpu = "/nix/store/fff-cmake.drv\n/nix/store/ggg-go-1.25.drv"
cases = [
    ("a check that compiles nothing is built (a substitution or a no-op)", ("acer-swift", "deploy-activate-asus-b460m", "", ""), "build"),
    ("seeded: asus's deploy-activate check on acer, built against CUDA, is deferred", ("acer-swift", "deploy-activate-asus-b460m", todo, cuda), "foreign"),
    ("seeded: asus's deploy-schema check on acer pulls the same closure and is deferred too", ("acer-swift", "deploy-schema-asus-b460m", todo, cuda), "foreign"),
    ("and on msi", ("msi-ms7758", "deploy-schema-asus-b460m", todo, cuda), "foreign"),
    ("both on asus itself are built", ("asus-b460m", "deploy-schema-asus-b460m", todo, cuda), "build"),
    ("lenovo's own check, the hostname longer than the node name, is its own", ("lenovo-21CB001PMX", "deploy-activate-lenovo", todo, cuda), "build"),
    ("seeded: a check of no node built against CUDA fails the step on a host without CUDA, not silently deferred", ("msi-ms7758", "gpu-telemetry-exporter", todo, cuda), "nodeless"),
    ("the same on a host whose own system has CUDA is built", ("asus-b460m", "gpu-telemetry-exporter", todo, cuda, "1"), "build"),
    ("another host's Ollama built without CUDA (acer's CPU build) is built here", ("msi-ms7758", "deploy-activate-acer-swift", todo, cpu), "build"),
    ("a CUDA name in what is built, not in its inputs, does not count: inputs decide", ("acer-swift", "deploy-activate-msi-ms7758", "/nix/store/u-cuda-docs.drv", cpu), "build"),
    ("the pattern is anchored: barracuda is not CUDA", ("acer-swift", "deploy-activate-msi-ms7758", todo, "/nix/store/h-barracuda-1.0.drv"), "build"),
]
for what, args, want in cases:
    got = decide(*args)
    check(got == want, f"decide: {what}: {want} (got {got})")

SIDE = function("side_by_side")
with tempfile.TemporaryDirectory() as t:
    t = pathlib.Path(t)
    rec, times = t / "records", t / "times"
    stub = t / "record"
    stub.write_text(f'#!/usr/bin/env bash\necho "$*" >> "{rec}"\n')
    steps = []
    for name, body in (("slow-ok", "sleep 1; echo slow output"), ("fails", "echo the failing output; echo on stderr >&2; exit 3"),
                       ("fast-ok", "echo fast output"), ("killed", "echo before the kill; kill -9 $PPID")):
        f = t / name
        f.write_text(f"#!/usr/bin/env bash\n{body}\n")
        f.chmod(0o755)
        steps += [name, str(f)]
    stub.chmod(0o755)
    script = SIDE.replace("${lib.getExe record}", str(stub))
    left = re.findall(r"\$\{lib\.[^}]*\}", script)
    if left:
        sys.exit(f"FAIL (scripts/test-gate-steps.py): side_by_side has Nix interpolations the test does not stub: {left}")
    r = subprocess.run(["bash", "-euo", "pipefail", "-c", script + '\nsha=abc\nside_by_side "$@"', "qa", *steps],
                       capture_output=True, text=True, env=dict(os.environ, NIXOS_QA_TIMES=str(times)))
    out = r.stdout
    check(r.returncode != 0 and "failed side by side: fails killed" in r.stderr,
          f"seeded: one failing step fails the run and is named ({r.returncode}, {r.stderr.strip()!r})")
    check("== fails: fail\nthe failing output\non stderr" in out, f"its own output is printed whole, stderr included ({out!r})")
    check(out.index("== slow-ok") < out.index("== fails") < out.index("== fast-ok") and "slow output" in out and "fast output" in out,
          "every step's output is printed, in the given order, after all ended")
    lines = times.read_text().splitlines()
    check([l.split()[1] for l in lines] == ["slow-ok", "fails", "fast-ok", "killed"] and all(l.endswith(" s") for l in lines),
          f"each step's seconds go to NIXOS_QA_TIMES ({lines})")
    recs = rec.read_text().splitlines()
    check(len(recs) == 4 and "step=fails" in recs[1] and "result=fail" in recs[1] and "result=pass" in recs[0] and "sha=abc" in recs[2],
          f"each step is recorded with its result ({recs})")
    check("no result written (killed?)" in out and "before the kill" in out and "step=killed seconds=0 result=fail" in recs[3] and "each step's log in" in out,
          f"seeded: a step whose subshell died before writing its result still has its log printed and counts as failed ({recs[3]!r})")
    # all three ran at once: the slow one did not hold back the others' start
    check(int(lines[0].split()[3]) >= 1 and int(lines[2].split()[3]) <= 1, f"the steps ran side by side ({lines})")

# nixos-flake-check's own body on a fake flake, acer-swift: asus's deploy-schema check would compile against CUDA
fc = re.search(r"\n  flakeCheck =\s+gate\s+\"nixos-flake-check\".*?''\n(.*?)\n *'';\n", src, re.S)
check(fc is not None, "flakeCheck found in devenv.nix")
names = {"nixosConfigurations": [], "formatter": [], "packages": [], "checks": ["x86_64-linux"],
         "checks.x86_64-linux": ["deploy-schema-asus-b460m", "plain"]}
# the dry-run text is Nix 2.34's own: "these N derivations" or "this derivation will be built:", and "don't know how to
# build these paths:" for a missing drv, with exit status 0
dryruns = {
    "defer": "these 2 derivations will be built:\\n  /nix/store/a-ollama-0.40.3.drv\\n  /nix/store/b-etc.drv",
    "single": "this derivation will be built:\\n  /nix/store/a-ollama-0.40.3.drv",
    "unknown": "don't know how to build these paths:\\n  /nix/store/0-missing.drv",
    "fails": None,
    # the same check on its own node (uname asus-b460m): built there, and recorded as built for the head; under
    # NIXOS_FLAKE_CHECK_DRY nothing is built, so it is recorded as dry
    "owner": "these 2 derivations will be built:\\n  /nix/store/a-ollama-0.40.3.drv\\n  /nix/store/b-etc.drv",
    "ownerdry": "these 2 derivations will be built:\\n  /nix/store/a-ollama-0.40.3.drv\\n  /nix/store/b-etc.drv",
}
for mode, dryrun in dryruns.items():
    with tempfile.TemporaryDirectory() as t:
        t = pathlib.Path(t)
        calls, rec, deferred = t / "calls", t / "records", t / "deferred"
        (t / "nix").write_text("#!/usr/bin/env python3\nimport json, sys\na = sys.argv[1:]\n"
                               f"open({str(calls)!r}, 'a').write(' '.join(a) + '\\n')\n"
                               f"names = {names!r}\n"
                               "attr = next((x[2:] for x in a if x.startswith('.#')), '')\n"
                               "if a[:2] == ['flake', 'show']: print(json.dumps({k: 0 for k in ['checks','deploy','formatter','nixosConfigurations','overlays','packages','templates']}))\n"
                               "elif '--expr' in a: print('x86_64-linux', end='')\n"
                               "elif any('? driver' in x for x in a): print(json.dumps([]))\n"
                               "elif 'builtins.attrNames' in a: print(json.dumps(names.get(attr, [])))\n"
                               "elif a[:2] == ['eval', '--raw'] and attr.endswith('.drvPath'): print('/nix/store/x-' + attr[:-8] + '.drv', end='')\n"
                               + ("elif '--dry-run' in a and 'asus' in a[-1]: print('error: path is not valid', file=sys.stderr); sys.exit(1)\n" if dryrun is None else
                                  f"elif '--dry-run' in a and 'asus' in a[-1]: print({dryrun!r}.replace('\\\\n', '\\n'), file=sys.stderr)\n"))
        # this guest's own system has no CUDA (-qR /run/current-system); the to-build derivations' inputs do
        (t / "nix-store").write_text('#!/usr/bin/env bash\n[ "$2" = -qR ] && exit 0\necho /nix/store/c-cuda13.4-cuda_cudart-13.4.drv\n')
        (t / "uname").write_text(f"#!/usr/bin/env bash\necho {'asus-b460m' if mode.startswith('owner') else 'acer-swift'}\n")
        (t / "record").write_text(f'#!/usr/bin/env bash\necho "$*" >> "{rec}"\n')
        for f in ("nix", "nix-store", "uname", "record"):
            (t / f).chmod(0o755)
        body = textwrap.dedent(fc.group(1)).replace("${pkgs.coreutils}/bin/uname", str(t / "uname"))
        body = body.replace("${lib.getExe record}", str(t / "record")).replace("${gateHeavy}", gate_heavy.group(1)).replace("''$", "$")
        r = subprocess.run(["bash", "-euo", "pipefail", "-c", body], capture_output=True, text=True, cwd=t,
                           env={**os.environ, "PATH": f"{t}:{os.environ['PATH']}", "NIXOS_QA_DEFERRED": str(deferred),
                                "NIXOS_QA_HEAD": "0123abc", **({"NIXOS_FLAKE_CHECK_DRY": "1"} if mode == "ownerdry" else {})})
        built = [c for c in calls.read_text().splitlines() if c.startswith("build ") and "--dry-run" not in c]
        check(not any("--max-jobs" in c for c in calls.read_text().splitlines()), f"{mode}: no substitute attempt with --max-jobs 0")
        if mode in ("defer", "single"):
            check(r.returncode == 0 and not any("asus" in c for c in built) and any("plain" in c for c in built),
                  f"flake check on acer: asus's deploy-schema check is not compiled, the plain one is built ({r.returncode}, {built})")
            check("deferred checks.x86_64-linux.deploy-schema-asus-b460m to asus-b460m" in r.stderr and "cuda13.4-cuda_cudart" in r.stderr
                  and "not built here, deferred to their own host's gate: asus-b460m:checks.x86_64-linux.deploy-schema-asus-b460m" in r.stderr,
                  f"the deferral is printed with its reason and in the end summary ({r.stderr[-400:]!r})")
            check(deferred.read_text().split() == ["asus-b460m:checks.x86_64-linux.deploy-schema-asus-b460m"]
                  and "result=deferred" in rec.read_text() and "owner=asus-b460m" in rec.read_text() and "seconds=0" in rec.read_text()
                  and "head=0123abc" in rec.read_text() and "drv=/nix/store/x-checks.x86_64-linux.deploy-schema-asus-b460m.drv" in rec.read_text(),
                  f"{mode}: the deferral reaches nixos-qa's list as owner:check, and a deferred gate-step record for the head and drv")
        elif mode == "owner":
            check(r.returncode == 0 and any("asus" in c for c in built) and not deferred.exists(),
                  f"on asus its own deploy-schema check is built, not deferred ({r.returncode}, {built})")
            check("result=built" in rec.read_text() and "owner=asus-b460m" in rec.read_text() and "head=0123abc" in rec.read_text()
                  and "check=checks.x86_64-linux.deploy-schema-asus-b460m" in rec.read_text() and "drv=/nix/store/x-" in rec.read_text(),
                  f"the owning host records its own deploy check as built for the head and drv ({rec.read_text()!r})")
        elif mode == "ownerdry":
            check(r.returncode == 0 and "result=dry" in rec.read_text() and "result=built" not in rec.read_text(),
                  f"seeded: under NIXOS_FLAKE_CHECK_DRY the owner records dry, never built ({rec.read_text()!r})")
        else:
            check(r.returncode != 0 and "the dry-run of checks.x86_64-linux.deploy-schema-asus-b460m failed" in r.stderr and not built,
                  f"seeded: a dry-run that {'exits non-zero' if dryrun is None else 'cannot find the derivation'} fails the step, not read as nothing to build ({r.returncode}, {r.stderr[-200:]!r})")

# and the step's own dry-run parsing on this nix's real output: a fresh derivation (instantiated, never built) must be the
# one line of "would compile", and a missing one must hit the step's failure test
awk = re.search(r"todo=\$\(awk '([^']*)' <<<\"\$dry\"\)", src)
check(awk is not None, "the step's dry-run awk is found")
# one parse: scripts/gate_defer.py (the gpu test's rule) reads the same dry-run texts as the flake check's awk
for mode, dryrun in dryruns.items():
    if dryrun is None or awk is None:
        continue
    text = dryrun.replace("\\n", "\n")
    by_awk = subprocess.run(["awk", awk.group(1)], input=text, capture_output=True, text=True, check=False).stdout.split()
    check(gate_defer.to_build(text) == by_awk, f"{mode}: gate_defer.to_build and the flake check's awk list the same derivations ({by_awk})")
if awk:
    import shutil, time
    nix = shutil.which("nix")
    if nix is None:
        check(False, "nix is on PATH for the real dry-run check")
    else:
        expr = f'derivation {{ name = "gate-steps-{time.time_ns()}"; system = builtins.currentSystem; builder = "/bin/sh"; args = [ "-c" "echo > $out" ]; }}'
        drv = subprocess.run(["nix-instantiate", "--expr", expr], capture_output=True, text=True, check=True).stdout.strip()
        dry = subprocess.run([nix, "build", "--dry-run", "--no-link", drv + "^*"], capture_output=True, text=True)
        todo = subprocess.run(["awk", awk.group(1)], input=dry.stdout + dry.stderr, capture_output=True, text=True).stdout.split()
        check(dry.returncode == 0 and todo == [drv], f"real nix: a derivation to build is the one parsed line ({todo}, {dry.stderr.strip()!r})")
        miss = subprocess.run([nix, "build", "--dry-run", "--no-link", "/nix/store/00000000000000000000000000000000-missing.drv^*"],
                              capture_output=True, text=True)
        check(miss.returncode != 0 or "know how to build" in miss.stderr,
              f"real nix: a missing derivation fails the dry-run or says it does not know how to build it ({miss.returncode}, {miss.stderr.strip()!r})")

finish()
