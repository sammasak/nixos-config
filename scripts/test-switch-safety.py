"""A switch does not fail on a bad ~/.claude.json: the activation step that pre-accepts Claude's dialogs leaves a
~/.claude.json that is not a JSON object alone instead of failing the switch.

Unit declarations from one evaluation, never a switch; the probe realises lenovo's activation script, which is then
run on throwaway homes."""
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


script = re.search(r"/nix/store/[^ ]+-accept-claude-startup-dialogs", s["claudeActivation"]).group(0)
VALID = '{"projects": {"/elsewhere": {}}, "theme": "light"}'
# None: no file yet; the activation creates it
for case, content in (("missing", None), ("valid", VALID), ("empty", ""), ("half-written", '{"projects": {'), ("an array", "[]"),
                      ("two documents", '{"a": 1}\n{"b": 2}\n'), ("an object jq cannot update", '{"projects": 5}')):
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
            # jq's own message may quote the file's content, which must never reach the journal
            ok = after == content and run.stderr.startswith("accept-claude-startup-dialogs:") and run.stderr.count("\n") == 1
            outcome = "left it untouched with one line of warning"
        check(run.returncode == 0 and ok and not stray,
              f"~/.claude.json {case}: the activation exits {run.returncode} and {outcome}{f', stray files {stray}' if stray else ''}")

sys.exit(1 if failed else 0)
