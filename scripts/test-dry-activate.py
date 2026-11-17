#!/usr/bin/env python3
"""`just dry-activate HOST` against stub nix, ssh, sudo and systemd-run on PATH and a stub system-checks.sh: deploy-rs's
--dry-activate exits 0 whatever the dry activation did, so the recipe runs switch-to-configuration dry-activate again
over ssh and exits non-zero, with its output, when that fails, and 0 when it passes; the closure diff runs either way."""
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


STUBS = {
    "systemd-run": 'echo "systemd-run $*" >> "$LOG"; while [ "${1:-}" != nix ]; do shift; done; exec "$@"',
    # `nix run … deploy-rs -- …` is deploy-rs, which prints success over a failed dry activation
    "nix": """echo "nix $*" >> "$LOG"
case "$*" in
  run*) echo "Completed dry-activate!" ;;
  *toplevel*) printf '%s' "$FIX/top" ;;
  *hostname*) printf target ;;
esac""",
    "ssh": 'echo "ssh $*" >> "$LOG"; shift 3; exec bash -c "$*"',
    "sudo": 'echo "sudo $*" >> "$LOG"; exec "$@"',
}


def run(dry_rc):
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        stubs = {f"bin/{n}": b for n, b in STUBS.items()}
        stubs["scripts/system-checks.sh"] = 'echo "system-checks $*" >> "$LOG"'
        stubs["top/bin/switch-to-configuration"] = 'echo "would restart: x.service"; [ "$1" = dry-activate ]; exit "$DRY_RC"'
        for rel, body in stubs.items():
            (tmp / rel).parent.mkdir(parents=True, exist_ok=True)
            (tmp / rel).write_text("#!/usr/bin/env bash\n" + body + "\n")
            (tmp / rel).chmod(0o755)
        (tmp / "log").touch()
        out = subprocess.run([shutil.which("just"), "--justfile", str(ROOT / "Justfile"), "--working-directory", str(tmp),
                              "dry-activate", "acer-swift"], capture_output=True, text=True,
                             env=dict(os.environ, PATH=f"{tmp / 'bin'}:{os.environ['PATH']}", FIX=str(tmp),
                                      LOG=str(tmp / "log"), DRY_RC=str(dry_rc)))
        return out.returncode, out.stdout + out.stderr, (tmp / "log").read_text()


rc, out, log = run(0)
check(rc == 0 and "--dry-activate" in log,
      f"a passing dry activation exits 0 (rc {rc}: {out.strip()})")
check("ssh -o StrictHostKeyChecking=yes deploy@target sudo " in log and "/top/bin/switch-to-configuration dry-activate" in log
      and "diff-closures /run/current-system" in log,
      "the dry activation reruns on the node's hostname through the deploy user's sudo, then the closure diff")
check("would restart" not in out, "a passing rerun stays quiet: deploy-rs already printed its output")

rc, out, log = run(3)
check(rc != 0 and "Completed dry-activate!" in out and "dry activation of acer-swift failed (exit 3)" in out,
      f"a seeded failing dry activation exits non-zero even though deploy-rs reported success (rc {rc}: {out.strip()})")
check("would restart: x.service" in out and "diff-closures" in log,
      "the failing run's output is printed and the closure diff still runs")

sys.exit(1 if failed else 0)
