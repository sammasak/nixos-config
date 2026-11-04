"""nixos-config#92: the documented rollback (nativeOtel = false in lenovo's variables.nix) restores the pre-canary state.

Copies the tracked tree, flips the one switch the runbook names, and evaluates both trees. The live canary must carry
every telemetry surface (so the test can tell the states apart); the rolled-back tree must carry none of them and must
match acer, a host that never had the canary, on the Claude environment.
"""
import json
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
VARS = "hosts/lenovo-21CB001PMX/variables.nix"
HM = "config.home-manager.users.lukas"
failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


def ev(flake, host, attr, raw=False, apply=None):
    cmd = ["nix", "eval", "--raw" if raw else "--json", f"{flake}#nixosConfigurations.{host}.{attr}"]
    if apply:
        cmd += ["--apply", apply]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"nix eval {host}.{attr} failed:\n{out.stderr[-800:]}")
    return out.stdout if raw else json.loads(out.stdout)


def surfaces(flake, host):
    env = ev(flake, host, f"{HM}.programs.claude-code.settings.env")
    codex = ev(flake, host, f'{HM}.home.file.".codex/config.toml".text', raw=True)
    fish = " ".join(ev(flake, host, f"{HM}.programs.fish.functions.{f}", raw=True) for f in ("claude", "codex"))
    relay = ev(flake, host, "config.systemd.services", apply='s: s ? "native-otel-relay"')
    secret = ev(flake, host, "config.sops.secrets", apply='s: s ? "native_otlp_auth"')
    return {"env": env, "codex_otel": "[otel]" in codex, "fish_otel": "OTEL_" in fish, "relay": relay, "secret": secret}


def main():
    live = surfaces(f"path:{ROOT}", "lenovo")
    otel_keys = sorted(k for k in live["env"] if k.startswith("OTEL_") or k == "CLAUDE_CODE_ENABLE_TELEMETRY")
    check(otel_keys and live["codex_otel"] and live["fish_otel"] and live["relay"] and live["secret"] and "DISABLE_TELEMETRY" not in live["env"],
          f"control: the live canary carries every surface ({len(otel_keys)} Claude telemetry keys, Codex [otel], Fish preludes, relay, secret)")
    with tempfile.TemporaryDirectory() as tmp:
        # tracked files as they are in the working tree, so both sides evaluate the same edits
        files = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z"], capture_output=True, check=True).stdout
        packed = subprocess.run(["tar", "-C", str(ROOT), "--null", "-T", "-", "-c"], input=files, capture_output=True, check=True).stdout
        subprocess.run(["tar", "-x", "-C", tmp], input=packed, check=True)
        vars_file = pathlib.Path(tmp, VARS)
        text, n = re.subn(r"nativeOtel = true;", "nativeOtel = false;", vars_file.read_text())
        check(n == 1, f"the runbook's switch exists exactly once in {VARS}")
        vars_file.write_text(text)
        back = surfaces(f"path:{tmp}", "lenovo")
    leftover = sorted(k for k in back["env"] if k.startswith("OTEL_") or k == "CLAUDE_CODE_ENABLE_TELEMETRY")
    check(not leftover, f"rolled back: no Claude telemetry variable is left (left: {leftover})")
    check(back["env"].get("DISABLE_TELEMETRY") == "1", "rolled back: Claude's standard telemetry-disable setting is restored")
    check(not back["codex_otel"], "rolled back: Codex's [otel] exporter stanza is gone")
    check(not back["fish_otel"], "rolled back: the claude and codex Fish functions set no OTEL_ variable")
    check(not back["relay"] and not back["secret"], "rolled back: the relay service and the receiver secret are no longer installed")
    acer = ev(f"path:{ROOT}", "acer-swift", f"{HM}.programs.claude-code.settings.env")
    check(back["env"] == acer, f"rolled back: lenovo's Claude environment equals acer's, a host that never had the canary (diff: {sorted(set(back['env'].items()) ^ set(acer.items()))})")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
