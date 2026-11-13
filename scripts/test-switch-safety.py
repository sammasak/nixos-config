"""A switch can neither kill the agent sessions on a host nor wait forever on a unit: Herdr's user server is kept
across a switch on every host that runs it (a restart ends every pane and agent); flux-bootstrap, a oneshot with
no default start timeout, gives up after a bounded time; the activation step that pre-accepts Claude's dialogs
leaves a ~/.claude.json that is not a JSON object alone instead of failing the switch.

Evaluation only (unit declarations, never a build or a switch), plus lenovo's activation script run on throwaway
homes."""
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

import gate_probe

failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


s = gate_probe.section("switch-safety")

herdr = {h: u for h, u in s["herdr"].items() if u is not None}
check({"lenovo", "acer-swift", "msi-ms7758"} <= herdr.keys(), f"the agent hosts run a Herdr server ({sorted(herdr)})")
for host, unit in sorted(herdr.items()):
    check(unit["X-SwitchMethod"] == "keep-old", f"{host}: a switch keeps the running Herdr server ({unit})")

flux = {h: u for h, u in s["flux"].items() if u is not None}
check(sorted(flux) == ["lenovo"], f"only lenovo bootstraps Flux ({sorted(flux)})")
for host, unit in sorted(flux.items()):
    check(unit["Type"] == "oneshot" and unit.get("TimeoutStartSec") == "10min",
          f"{host}: flux-bootstrap's start is bounded, a switch waits at most 10 min on it ({unit})")

script = re.search(r"/nix/store/[^ ]+-accept-claude-startup-dialogs", s["claudeActivation"]).group(0)
VALID = '{"projects": {"/elsewhere": {}}, "theme": "light"}'
# None: no file yet; the activation creates it
for case, content in (("missing", None), ("valid", VALID), ("empty", ""), ("half-written", '{"projects": {'), ("an array", "[]"),
                      ("an object jq cannot update", '{"projects": 5}')):
    with tempfile.TemporaryDirectory() as home:
        state = pathlib.Path(home, ".claude.json")
        if content is not None:
            state.write_text(content)
        run = subprocess.run([script], env={**os.environ, "HOME": home}, capture_output=True, text=True)
        after = state.read_text()
        stray = sorted(p.name for p in pathlib.Path(home).iterdir() if p.name != ".claude.json")
        if content in (None, VALID):
            got = json.loads(after)
            kept = content is None or (got["theme"] == "light" and "/elsewhere" in got["projects"])
            ok = (got.get("bypassPermissionsModeAccepted") is True and got["projects"][home]["hasTrustDialogAccepted"] is True
                  and kept and state.stat().st_mode & 0o777 == 0o600)
            outcome = "accepted the dialogs, kept its other keys, mode 0600"
        else:
            ok = after == content and "leaving it alone" in run.stderr
            outcome = "left it untouched with a warning"
        check(run.returncode == 0 and ok and not stray,
              f"~/.claude.json {case}: the activation exits {run.returncode} and {outcome}{f', stray files {stray}' if stray else ''}")

sys.exit(1 if failed else 0)
