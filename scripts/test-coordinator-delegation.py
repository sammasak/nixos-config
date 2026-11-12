"""lenovo's generated ~/claude-code-skills/devenv.local.nix delegates approval to an interactive Coordinator session.

The file is rendered from the host's sam.herdr.coordinatorWakeup options, written into a writable copy of the
pinned skills input, and exercised with real devenv and the skills repo's own fake gh: gh:label approved on an
owner issue is accepted with the decision on both audit lines; with mayApprove = false it is refused before any
gh call. devenv comes from PATH (the system profile on the hosts, as for the interactive session)."""
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

import gate_probe

DECISION = "https://github.com/sammasak/skills/issues/28#issuecomment-6629911996"
APPROVE = '{"repo":"sammasak/skills","number":36,"label":"approved","action":"add","reason":"fits a worker: no live hardware"}'
failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


def main():
    global failed
    if shutil.which("devenv") is None:
        check(False, "devenv is on PATH (the system profile)")
        sys.exit(1)
    P = gate_probe.section("delegation")
    text = P["local"]
    check(f'coordinator.mayApprove = true;' in text and f'coordinator.approvalDecision = "{DECISION}";' in text
          and 'coordinator.panes = "lenovo-21CB001PMX/wM:p1";' in text and "do not add it" in text,
          "lenovo renders devenv.local.nix with the delegation, the owner's decision comment and the Coordinator pane")
    off = text.replace("coordinator.mayApprove = true;", "coordinator.mayApprove = false;")
    check(off != text, "the off variant differs only in mayApprove")
    skills = P["skills"]
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        copy = tmp / "skills"
        shutil.copytree(skills, copy)
        for p in copy.rglob("*"):
            try:
                p.chmod(p.stat().st_mode | 0o200)
            except OSError:
                pass
        copy.chmod(copy.stat().st_mode | 0o200)
        env = dict(os.environ, FAKE_GH_LABELS='["enhancement"]')
        env.pop("FAKE_GH_ISSUE_IS_PR", None)
        fakes = subprocess.run(["devenv", "build", "coordinator.fakes"], cwd=copy, env=env, capture_output=True, text=True)
        store = re.findall(r"/nix/store/[a-z0-9]+-coordinator-fakes", fakes.stdout)   # devenv build prints a JSON object
        check(fakes.returncode == 0 and store, f"the pinned skills input builds its fake gh ({fakes.stderr[-300:].strip()})")
        if not store:
            sys.exit(1)
        gh = store[0] + "/bin/gh"

        def run(variant, name):
            (copy / "devenv.local.nix").write_text(variant)
            state = tmp / f"state-{name}"
            state.mkdir()
            log = state / "calls.log"
            r = subprocess.run(["devenv", "tasks", "run", "gh:label", "--option", f"coordinator.ghCommand:string", gh,
                                "--option", "coordinator.stateDir:string", str(state), "--input-json", APPROVE, "--show-output"],
                               cwd=copy, env=dict(env, FAKE_LOG=str(log)), capture_output=True, text=True)
            rec = None
            for line in (r.stdout + r.stderr).splitlines():   # a failed task's record lands on stderr
                line = line.strip()
                if line.startswith("{"):
                    try:
                        obj = json.loads(line)
                    except ValueError:
                        continue
                    obj = obj.get("gh:label", obj if obj.get("task") == "gh:label" else None)
                    if obj:
                        rec = obj
            audit = [json.loads(l) for l in (state / "audit.jsonl").read_text().splitlines()] if (state / "audit.jsonl").exists() else []
            calls = log.read_text() if log.exists() else ""
            return r.returncode, rec or {}, audit, calls

        code, rec, audit, calls = run(text, "on")
        check(code == 0 and rec.get("outcome") == "done" and (rec.get("owner_delegation") or {}).get("decision") == DECISION,
              f"with the generated file, gh:label approved on an owner issue is accepted and cites the decision (exit {code}, {json.dumps(rec)[:160]})")
        check(len(audit) == 2 and all(a.get("label") == "approved" and (a.get("owner_delegation") or {}).get("decision") == DECISION for a in audit)
              and audit[-1].get("outcome") == "done",
              f"both audit lines carry owner_delegation with the decision and the outcome is done ({len(audit)} lines)")
        check(calls.splitlines() == ["gh api repos/sammasak/skills/issues/36", "gh api -X POST repos/sammasak/skills/issues/36/labels --input -"],
              f"one issue read, then one POST of the label ({calls.strip()!r})")
        code, rec, audit, calls = run(off, "off")
        check(code != 0 and (rec.get("error") or {}).get("kind") == "not_delegated" and audit == [] and calls == "",
              f"with mayApprove = false the same act is refused as not_delegated before any gh call or audit line (exit {code}, {json.dumps(rec.get('error'))[:160]})")
    sys.exit(1 if failed else 0)


main()
