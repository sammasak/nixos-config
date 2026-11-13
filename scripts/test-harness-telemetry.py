"""sam.claude.telemetry on lenovo (nativeOtel): Claude exports to the local relay, which adds the token, with session and
repository attributes, no content, and the HARNESS_ copies its emit-work-ref.sh hook reads; the hook runs on Stop after
check-git-state.sh and on SessionStart only while the skills pin carries it. Off, none of it. Both skills sources are
evaluated, whichever the pin is: the pinned one and a copy with the hook added, or removed (--override-input)."""
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

import gate_probe

ROOT = pathlib.Path(__file__).resolve().parent.parent
HOOK = "emit-work-ref.sh"
SKILL_HOOK = "emit-skill-use.sh"
RELAY = "http://127.0.0.1:4319"
failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


def commands(s):
    return [h["command"] for entries in s["hooks"].values() for e in entries for h in e["hooks"]]


def flipped(skills, tmp, has):
    fixture = pathlib.Path(tmp, "skills")
    shutil.copytree(skills, fixture, symlinks=True)
    for p in [fixture, *fixture.rglob("*")]:
        if not p.is_symlink():
            p.chmod(p.stat().st_mode | 0o200)
    for f in (fixture / "hooks" / h for h in (HOOK, SKILL_HOOK)):
        if has:
            f.unlink(missing_ok=True)
        else:
            f.write_text("#!/bin/sh\nexit 0\n")
            f.chmod(0o755)
    out = subprocess.run(
        ["nix", "eval", "--json", "--impure", "--no-write-lock-file", "--override-input", "skills", f"path:{fixture}",
         f"{ROOT}#nixosConfigurations", "--apply", f"import {ROOT}/scripts/harness-telemetry-probe.nix"],
        capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"nix eval with the flipped skills source failed:\n{out.stderr[-800:]}")
    return json.loads(out.stdout)


def env_checks(P):
    on, off = P["on"]["env"], P["off"]["env"]
    check(on.get("OTEL_EXPORTER_OTLP_ENDPOINT") == RELAY and on.get("OTEL_EXPORTER_OTLP_PROTOCOL") == "http/protobuf"
          and on.get("OTEL_METRICS_EXPORTER") == on.get("OTEL_LOGS_EXPORTER") == "otlp" and "OTEL_EXPORTER_OTLP_HEADERS" not in on,
          f"on: metrics and logs go to the loopback relay over http/protobuf, with no header of Claude's own ({on.get('OTEL_EXPORTER_OTLP_ENDPOINT')})")
    check(on.get("OTEL_METRICS_INCLUDE_SESSION_ID") == "true" and on.get("OTEL_METRICS_INCLUDE_REPOSITORY") == "true",
          "on: events carry session.id, events and metrics the repository")
    check(all(on.get(k) == "0" for k in ("OTEL_LOG_USER_PROMPTS", "OTEL_LOG_TOOL_CONTENT", "OTEL_LOG_TOOL_DETAILS", "OTEL_LOG_RAW_API_BODIES")),
          "on: every content flag is 0")
    check(on.get("HARNESS_OTLP_ENDPOINT") == RELAY and on.get("HARNESS_RESOURCE_ATTRIBUTES") == on.get("OTEL_RESOURCE_ATTRIBUTES") == "host.name=lenovo-21cb001pmx",
          f"on: HARNESS_OTLP_ENDPOINT is the relay and HARNESS_RESOURCE_ATTRIBUTES equals OTEL_RESOURCE_ATTRIBUTES ({on.get('HARNESS_RESOURCE_ATTRIBUTES')})")
    left = sorted(k for k in off if k.startswith(("OTEL_", "HARNESS_")) or k == "CLAUDE_CODE_ENABLE_TELEMETRY")
    check(not left and off.get("DISABLE_TELEMETRY") == "1", f"off: no telemetry or HARNESS_ variable ({left})")


def with_hook(P, src):
    on, off = P["on"], P["off"]
    stop = [[h["command"] for h in e["hooks"]] for e in on["hooks"]["Stop"]]
    check(len(stop) == 1 and len(stop[0]) == 2 and stop[0][0].endswith("/hooks/check-git-state.sh") and stop[0][1].endswith(f"{src}/hooks/{HOOK}"),
          f"on: Stop runs check-git-state.sh, then {HOOK} ({stop})")
    starts = [e for e in on["hooks"]["SessionStart"] if any(h["command"].endswith(HOOK) for h in e["hooks"])]
    hook = starts[0]["hooks"][0] if len(starts) == 1 and len(starts[0]["hooks"]) == 1 else {}
    path = hook.get("command", "").split(" ", 1)[0]
    check(hook.get("timeout") == 5 and all(f"-{t}-" in path for t in ("jq", "coreutils", "curl", "git")),
          f"on: one SessionStart entry runs {HOOK} with jq, coreutils, curl and git on PATH, timeout 5 ({starts})")
    rest = lambda s: {k: [e for e in v if not any(h["command"].endswith(HOOK) for h in e["hooks"])] for k, v in s["hooks"].items()}
    check(rest(on)["SessionStart"] == off["hooks"]["SessionStart"], "on: the other SessionStart entries are unchanged")
    check(not any(c.endswith((HOOK, SKILL_HOOK)) for c in commands(off)), f"off: no {HOOK} or {SKILL_HOOK} even with the pin carrying them")
    skill = {k: [e for e in on["hooks"].get(k, []) if any(h["command"].endswith(SKILL_HOOK) for h in e["hooks"])] for k in on["hooks"]}
    where = {k: [(e.get("matcher"), len(e["hooks"]), e["hooks"][0].get("timeout")) for e in v] for k, v in skill.items() if v}
    path = next((e["hooks"][0]["command"].split(" ", 1)[0] for v in skill.values() for e in v), "")
    check(where == {"PreToolUse": [("Skill", 1, 5)], "UserPromptSubmit": [(None, 1, 5)]} and all(f"-{t}-" in path for t in ("jq", "coreutils", "curl")),
          f"on: {SKILL_HOOK} runs alone on PreToolUse(Skill) and UserPromptSubmit with jq, coreutils and curl on PATH, timeout 5 ({where})")


def without_hook(P):
    check(not any(c.endswith((HOOK, SKILL_HOOK)) for c in commands(P["on"])) and P["on"]["hooks"] == P["off"]["hooks"],
          f"on with a pin lacking {HOOK} and {SKILL_HOOK}: the hooks are the off ones")


def main():
    P = gate_probe.section("harness-telemetry")
    skills = P["skills"]
    has = all(pathlib.Path(skills, "hooks", h).exists() for h in (HOOK, SKILL_HOOK))
    print(f"pinned skills {skills} {'carries' if has else 'lacks'} {HOOK} and {SKILL_HOOK}")
    env_checks(P)
    with tempfile.TemporaryDirectory() as tmp:
        F = flipped(skills, tmp, has)
        src = next(c.split(" ")[-1].rsplit("/hooks/", 1)[0] for c in commands(F["off"]) if "/hooks/check-git-state.sh" in c)
    with_hook(*((P, skills) if has else (F, src)))
    without_hook(F if has else P)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
