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

ROOT = pathlib.Path(__file__).resolve().parent.parent
failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


src = (ROOT / "devenv.nix").read_text()


def function(name):
    m = re.search(r"\n( *)" + name + r"\(\) \{\n.*?\n\1\}\n", src, re.S)
    if not m:
        sys.exit(f"FAIL: {name}() not found in devenv.nix")
    return textwrap.dedent(m.group(0)).replace("''${", "${")


heavy = re.search(r"\n *(heavy='[^']*')\n", src)
if not heavy:
    sys.exit("FAIL: heavy= not found in devenv.nix")
DECIDE = heavy.group(1) + "\n" + function("decide")


def decide(here, check_name, drv, base, todo, inputs=""):
    r = subprocess.run(["bash", "-euo", "pipefail", "-c", DECIDE + '\ndecide "$@"', "decide", here, check_name, drv, base, todo, inputs],
                       capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else f"rc={r.returncode} {r.stderr.strip()}"


# what a dry-run of asus's deploy check lists on acer: the CUDA Ollama is plain ollama-0.x by name, its inputs say CUDA
todo = "/nix/store/aaa-ollama-0.40.3.drv\n/nix/store/bbb-unit-ollama.service.drv"
cuda = "/nix/store/ccc-cuda13.4-cuda_cudart-13.4.92.drv\n/nix/store/ddd-nvidia-x11-595.104.02.drv\n/nix/store/eee-cmake.drv"
cpu = "/nix/store/fff-cmake.drv\n/nix/store/ggg-go-1.25.drv"
cases = [
    ("a check that compiles nothing is built (a substitution or a no-op)", ("msi-ms7758", "deploy-activate-asus-b460m", "/d1", "", ""), "build"),
    ("a check whose drv equals main's is not built", ("msi-ms7758", "llm-bench-scorecard", "/d1", "/d1", "/nix/store/x.drv"), "unchanged"),
    ("seeded: a changed check is built", ("msi-ms7758", "llm-bench-scorecard", "/d2", "/d1", "/nix/store/x.drv"), "build"),
    ("a check new since main (no base drv) is built", ("msi-ms7758", "new-check", "/d2", "", "/nix/store/x.drv"), "build"),
    ("seeded: another host's changed closure built against CUDA is left to that host", ("acer-swift", "deploy-activate-asus-b460m", "/d2", "/d1", todo, cuda), "foreign"),
    ("the same closure on its own host is built", ("asus-b460m", "deploy-activate-asus-b460m", "/d2", "/d1", todo, cuda), "build"),
    ("lenovo's own check, the hostname longer than the node name, is its own", ("lenovo-21CB001PMX", "deploy-activate-lenovo", "/d2", "/d1", todo, cuda), "build"),
    ("another host's Ollama built without CUDA (acer's CPU build) is built here", ("msi-ms7758", "deploy-activate-acer-swift", "/d2", "/d1", todo, cpu), "build"),
    ("a CUDA name in what is built, not in its inputs, does not count: inputs decide", ("acer-swift", "deploy-activate-msi-ms7758", "/d2", "/d1", "/nix/store/u-cuda-docs.drv", cpu), "build"),
    ("an unchanged CUDA closure of another host is not built either", ("acer-swift", "deploy-activate-asus-b460m", "/d1", "/d1", todo, cuda), "unchanged"),
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
                       ("fast-ok", "echo fast output")):
        f = t / name
        f.write_text(f"#!/usr/bin/env bash\n{body}\n")
        f.chmod(0o755)
        steps += [name, str(f)]
    stub.chmod(0o755)
    script = SIDE.replace("${lib.getExe record}", str(stub))
    left = re.findall(r"\$\{lib\.[^}]*\}", script)
    if left:
        sys.exit(f"FAIL: side_by_side has Nix interpolations the test does not stub: {left}")
    r = subprocess.run(["bash", "-euo", "pipefail", "-c", script + '\nsha=abc\nside_by_side "$@"', "qa", *steps],
                       capture_output=True, text=True, env=dict(os.environ, NIXOS_QA_TIMES=str(times)))
    out = r.stdout
    check(r.returncode != 0 and "failed side by side: fails" in r.stderr,
          f"seeded: one failing step fails the run and is named ({r.returncode}, {r.stderr.strip()!r})")
    check("== fails: fail\nthe failing output\non stderr" in out, f"its own output is printed whole, stderr included ({out!r})")
    check(out.index("== slow-ok") < out.index("== fails") < out.index("== fast-ok") and "slow output" in out and "fast output" in out,
          "every step's output is printed, in the given order, after all ended")
    lines = times.read_text().splitlines()
    check([l.split()[1] for l in lines] == ["slow-ok", "fails", "fast-ok"] and all(l.endswith(" s") for l in lines),
          f"each step's seconds go to NIXOS_QA_TIMES ({lines})")
    recs = rec.read_text().splitlines()
    check(len(recs) == 3 and "step=fails" in recs[1] and "result=fail" in recs[1] and "result=pass" in recs[0] and "sha=abc" in recs[2],
          f"each step is recorded with its result ({recs})")
    # all three ran at once: the slow one did not hold back the others' start
    check(int(lines[0].split()[3]) >= 1 and int(lines[2].split()[3]) <= 1, f"the steps ran side by side ({lines})")

sys.exit(1 if failed else 0)
