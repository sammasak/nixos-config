"""The rebuild trigger's rollback (modules/homelab/nixos-rebuild-trigger/activate.sh) without Nix: common.sh plus
activate.sh as default.nix builds them, with flock, the health probes, readlink, nix-env, nixos-rebuild and both
generations' switch-to-configuration stubbed. A failed health gate must switch back to the previous generation live,
make it the system profile's newest generation and its boot entry the default, and audit any step that fails. Seeded:
a failing boot-default step is audited, not swallowed; and main's old `nixos-rebuild boot --rollback || true`, which on
a flake-only host fails at its re-exec (no nixos-config on NIX_PATH) and changes nothing, fails this test."""
import os
import pathlib
import subprocess
import tempfile

from gate_probe import check, finish

ROOT = pathlib.Path(__file__).resolve().parent.parent
DIR = ROOT / "modules/homelab/nixos-rebuild-trigger"


def run(activate_text, **env):
    with tempfile.TemporaryDirectory() as t:
        t = pathlib.Path(t)
        log, stubs = t / "calls", t / "bin"
        stubs.mkdir()
        stub = {
            "flock": "exit 0",
            "ss": "exit 0",  # nothing listens on :22: the health gate fails
            "getent": "exit 2",
            "sleep": "exit 0",
            "readlink": f'echo "{t}/new"',
            "nix-env": f'echo "nix-env $*" >> "{log}"; exit "${{NIXENV_RC:-0}}"',
            # what asus showed: the re-exec builds from <nixpkgs/nixos> and fails before doing anything
            "nixos-rebuild": f'echo "nixos-rebuild $*" >> "{log}"; echo "error: file \'nixos-config\' was not found in the Nix search path" >&2; exit 1',
        }
        for name, body in stub.items():
            (stubs / name).write_text(f"#!/usr/bin/env bash\n{body}\n")
            (stubs / name).chmod(0o755)
        for gen in ("prev", "new"):
            (t / gen / "bin").mkdir(parents=True)
            rc = "${PREV_BOOT_RC:-0}" if gen == "prev" else "${NEW_RC:-0}"
            body = f'echo "{gen} switch-to-configuration $1" >> "{log}"; [ "$1" = boot ] && exit {rc}; [ "{gen}" = new ] && exit {rc}; exit 0'
            (t / gen / "bin" / "switch-to-configuration").write_text(f"#!/usr/bin/env bash\n{body}\n")
            (t / gen / "bin" / "switch-to-configuration").chmod(0o755)
        script = t / "activate"
        script.write_text("#!/usr/bin/env bash\nset -o errexit\nset -o nounset\nset -o pipefail\n"
                          + (DIR / "common.sh").read_text() + activate_text)
        script.chmod(0o755)
        audit, result = t / "audit", t / "result"
        r = subprocess.run([str(script), str(t / "prev"), "lukas", "abc", "2026-11-18T00:00:00"], capture_output=True, text=True,
                           env={"PATH": f"{stubs}:{os.environ['PATH']}", "AUDIT_LOG": str(audit), "RESULT_FILE": str(result),
                                "LOCK_FILE": str(t / "lock"), "HEALTH_TIMEOUT_SEC": "0", "TRIGGER_USER": "lukas", **env})
        calls = log.read_text().splitlines() if log.exists() else []
        return (r.returncode, calls, audit.read_text() if audit.exists() else "", r.stderr,
                str(t / "prev"))


def rolled_back(rc, calls, audit, prev):
    """A failed health gate ends with prev live, prev as the profile's newest generation and prev's boot entry."""
    return (rc == 1 and "result=failed-health-rolledback" in audit
            and calls[:1] == ["new switch-to-configuration switch"]
            and "prev switch-to-configuration switch" in calls
            and f"nix-env --profile /nix/var/nix/profiles/system --set {prev}" in calls
            and "prev switch-to-configuration boot" in calls
            and not any(c.startswith("nixos-rebuild") for c in calls))


new = (DIR / "activate.sh").read_text()
rc, calls, audit, err, prev = run(new)
check(rolled_back(rc, calls, audit, prev) and "rollback-incomplete" not in audit,
      f"a failed health gate rolls back live, in the system profile and in the boot default, without nixos-rebuild ({rc}, {calls})")

rc, calls, audit, err, prev = run(new, PREV_BOOT_RC="1")
check(rc == 1 and "result=rollback-incomplete failed=boot-default" in audit and "ROLLBACK INCOMPLETE" in err,
      f"seeded: a failing boot-default step is audited and printed, not swallowed ({audit.strip()[-160:]})")

rc, calls, audit, err, prev = run(new, NIXENV_RC="1", PREV_BOOT_RC="1")
check("result=rollback-incomplete failed=profile boot-default" in audit and "prev switch-to-configuration boot" in calls,
      "seeded: each rollback step runs after one before it failed, and all failures are named")

old = subprocess.run(["git", "-C", str(ROOT), "show", "origin/main:modules/homelab/nixos-rebuild-trigger/activate.sh"],
                     capture_output=True, text=True)
if old.returncode == 0 and "nixos-rebuild boot --rollback || true" in old.stdout:
    rc, calls, audit, err, prev = run(old.stdout)
    check(not rolled_back(rc, calls, audit, prev) and "rollback-incomplete" not in audit,
          f"seeded: the old `nixos-rebuild boot --rollback || true` fails this test: it never resets the boot default, "
          f"and its failure is silent ({calls})")
else:
    print("SKIP: origin/main's activate.sh no longer has the old line (already fixed there)")

finish()
