"""nixos-config#92: the documented rollback (nativeOtel = false in lenovo's variables.nix) restores the pre-canary state.

Copies the tracked tree, flips the one switch the runbook names, and evaluates both trees. The live canary must carry
every telemetry surface (so the test can tell the states apart); the rolled-back tree must carry none of them and must
match acer with the same switch off on the Claude environment.
"""
import json
import pathlib
import re
import subprocess
import sys
import tempfile

import gate_probe

ROOT = pathlib.Path(__file__).resolve().parent.parent
VARS = "hosts/lenovo-21CB001PMX/variables.nix"
failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


def surfaces(tree):
    """lenovo's telemetry surfaces in a copy of the tree (scripts/gate-probe.nix, the section the live tree's probe holds)."""
    out = subprocess.run(["nix", "eval", "--json", "--impure", "--expr", f'(import {tree}/scripts/gate-probe.nix {{ }}).sections.otel-rollback.live'],
                         capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"nix eval of lenovo in {tree} failed:\n{out.stderr[-800:]}")
    return json.loads(out.stdout)


def main():
    P = gate_probe.section("otel-rollback")
    live = P["live"]
    otel_keys = sorted(k for k in live["env"] if k.startswith("OTEL_") or k == "CLAUDE_CODE_ENABLE_TELEMETRY")
    wrapped = [p for p in live["codex"] if all(v in p["text"] for v in (
        'OTEL_RESOURCE_ATTRIBUTES="host.name=lenovo-21cb001pmx"', "OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=cumulative"))]
    check(otel_keys and live["codex_otel"] and len(wrapped) == 1 and live["relay"] and live["secret"] and "DISABLE_TELEMETRY" not in live["env"],
          f"control: the live canary carries every surface ({len(otel_keys)} Claude telemetry keys, Codex [otel], codex wrapper, relay, secret)")
    check(not live["fish_otel"], "live: no claude or codex Fish function sets an OTEL_ variable (the codex wrapper on PATH does)")
    with tempfile.TemporaryDirectory() as tmp:
        # tracked files as they are in the working tree, so both sides evaluate the same edits
        files = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z"], capture_output=True, check=True).stdout
        packed = subprocess.run(["tar", "-C", str(ROOT), "--null", "-T", "-", "-c"], input=files, capture_output=True, check=True).stdout
        subprocess.run(["tar", "-x", "-C", tmp], input=packed, check=True)
        vars_file = pathlib.Path(tmp, VARS)
        text, n = re.subn(r"nativeOtel = true;", "nativeOtel = false;", vars_file.read_text())
        check(n == 1, f"the runbook's switch exists exactly once in {VARS}")
        vars_file.write_text(text)
        back = surfaces(tmp)
    leftover = sorted(k for k in back["env"] if k.startswith("OTEL_") or k == "CLAUDE_CODE_ENABLE_TELEMETRY")
    check(not leftover, f"rolled back: no Claude telemetry variable is left (left: {leftover})")
    check(back["env"].get("DISABLE_TELEMETRY") == "1", "rolled back: Claude's standard telemetry-disable setting is restored")
    check(not back["codex_otel"], "rolled back: Codex's [otel] exporter stanza is gone")
    check(not back["fish_otel"], "rolled back: the claude and codex Fish functions set no OTEL_ variable")
    check([p["path"] for p in back["codex"]] == [back["plain_codex"]], f"rolled back: the only codex package is plain pkgs.codex ({back['codex']})")
    check(not back["relay"] and not back["secret"], "rolled back: the relay service and the receiver secret are no longer installed")
    acer = P["acer"]
    check(back["env"] == acer, f"rolled back: lenovo's Claude environment equals acer's with the switch off (diff: {sorted(set(back['env'].items()) ^ set(acer.items()))})")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
