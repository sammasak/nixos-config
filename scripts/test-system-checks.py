#!/usr/bin/env python3
"""scripts/system-checks.sh (just checks, run first by deploy and dry-activate) against stub nix, nix-store, ssh and
systemd-run on PATH: it lists each check as built or substituted on the build host, and it refuses, exiting non-zero
before any later step, an empty check list, a check that is not an input of the toplevel, an unreachable build host,
a check that fails to build and a check that is still not valid after the build."""
import json
import os
import pathlib
import subprocess
import tempfile

from gate_probe import check, finish

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts/system-checks.sh"


STUBS = {
    # the cap's properties dropped, the command run as given
    "systemd-run": 'echo "systemd-run $*" >> "$LOG"; while [ "${1:-}" != nix ]; do shift; done; exec "$@"',
    "nix": """echo "nix $*" >> "$LOG"
case $1 in
  eval) case "$*" in *deploy.nodes*) cat "$FIX/node.json" ;; *) cat "$FIX/plan.json" ;; esac ;;
  derivation) cat "$FIX/drv.json" ;;
  copy) [ -z "${UNREACHABLE:-}" ] || exit 1 ;;
  build) [ -z "${FAIL_BUILD:-}" ] || exit 1 ;;
  path-info) cat "$FIX/info.json" ;;
esac""",
    # the first call is before the build, every later one after it
    "nix-store": """echo "nix-store $*" >> "$LOG"
if [ -e "$FIX/built" ]; then printf '%s' "${INVALID_AFTER:-}"; else touch "$FIX/built"; printf '%s' "${INVALID_BEFORE:-}"; fi""",
    "ssh": """echo "ssh $*" >> "$LOG"
[ -z "${UNREACHABLE:-}" ] || exit 255
cmd=${!#}; exec bash -c "$cmd\"""",
}

TOP = "/nix/store/aaaa-nixos-system-host.drv"
CHECK = {"name": "check-a", "drvPath": "/nix/store/bbbb-check-a.drv", "out": "/nix/store/cccc-check-a"}


def run(checks=(CHECK,), inputs=("bbbb-check-a.drv",), remote=True, info=None, **env):
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        (tmp / "bin").mkdir()
        for name, body in STUBS.items():
            (tmp / "bin" / name).write_text("#!/usr/bin/env bash\n" + body + "\n")
            (tmp / "bin" / name).chmod(0o755)
        (tmp / "plan.json").write_text(json.dumps({"top": TOP, "checks": list(checks)}))
        (tmp / "node.json").write_text(json.dumps({"hostname": "target", "remoteBuild": remote}))
        (tmp / "drv.json").write_text(json.dumps({"derivations": {TOP.rsplit("/", 1)[1]: {"inputs": {"drvs": {d: {} for d in inputs}}}}}))
        (tmp / "info.json").write_text(json.dumps(info or {CHECK["out"]: {"ultimate": True, "signatures": []}}))
        (tmp / "log").touch()
        out = subprocess.run(["bash", str(SCRIPT), "host", "-p", "MemoryMax=7G"], capture_output=True, text=True,
                             env=dict(os.environ, PATH=f"{tmp / 'bin'}:{os.environ['PATH']}", FIX=str(tmp),
                                      LOG=str(tmp / "log"), **env))
        return out.returncode, out.stdout + out.stderr, (tmp / "log").read_text()


rc, out, log = run(INVALID_BEFORE=CHECK["out"])
remote = [line for line in log.splitlines() if line.startswith("ssh ") and "deploy@target" in line]
check(rc == 0 and "check-a" in out and "built now on target" in out and "nix copy --derivation" in log,
      f"a check missing on the remote build host is copied there, built and listed (rc {rc}: {out.strip()})")
check(all(any(step in line for line in remote) for step in ("nix build", "nix-store --check-validity", "nix path-info")),
      f"on a remote build host the build, the validity checks and path-info all go through ssh to it ({remote})")
check(log.count("systemd-run --user --scope -q -p MemoryMax=7G") == 2,
      "both evaluations run under the cap the caller passes (the Justfile's memcap)")
check("--json-format 1" in log and ".drv^*" in log, "path-info is asked for format 1 and the build for every output (^*)")
rc, out, log = run(remote=False, info={CHECK["out"]: {"ultimate": False, "signatures": ["acer-swift-store-1:xyz"]}})
check(rc == 0 and "already valid (substituted, signed by acer-swift-store-1 earlier)" in out and "ssh" not in log
      and "nix copy" not in log and "nix build" in log,
      f"a local build host builds here, runs no ssh or copy, and names the signer ({out.strip()})")

rc, out, log = run(checks=())
check(rc != 0 and "declares no system.checks" in out and "nix copy" not in log and "nix build" not in log,
      f"an empty check list is refused before anything is copied or built (rc {rc})")
rc, out, log = run(inputs=("dddd-other.drv",))
check(rc != 0 and "is not a build input" in out and "nix copy" not in log and "nix build" not in log,
      f"a check that is not an input of the toplevel is refused before anything is copied or built (rc {rc})")
rc, out, log = run(UNREACHABLE="1")
check(rc != 0 and "nix copy" in log and "nix build" not in log,
      f"an unreachable build host is refused at the copy, before anything is built (rc {rc})")
rc, out, log = run(FAIL_BUILD="1")
check(rc != 0 and "nix build" in log and "nix path-info" not in log, f"a check that fails to build is refused (rc {rc})")
rc, out, log = run(INVALID_AFTER=CHECK["out"])
check(rc != 0 and "still not valid" in out and "nix path-info" not in log,
      f"a check still not valid on the target after the build is refused (rc {rc})")

finish()
