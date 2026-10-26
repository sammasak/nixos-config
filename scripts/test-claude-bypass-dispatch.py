#!/usr/bin/env python3
"""claude-bypass dispatch: argument validation, exactly-once Fish dispatch, and
Herdr resume/attach. Stubs only (synthetic sessions, token and binaries); no
real Claude, Herdr server or secret is touched.

usage: test-claude-bypass-dispatch.py <home-manager fish functions dir>
"""
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

LAUNCHER = Path(__file__).resolve().parent.parent / "modules/programs/cli/herdr/agent-launcher.sh"
STUB = """#!{python}
import json, os, sys
with open(os.environ["STUB_CAPTURE"], "a") as out:
    out.write(json.dumps({{"tool": {tool!r}, "args": sys.argv[1:],
                          "has_header": bool(os.environ.get("OTEL_EXPORTER_OTLP_HEADERS"))}}) + "\\n")
if {tool!r} == "herdr":
    args = sys.argv[1:]
    if args[:2] == ["agent", "list"]:
        print(os.environ.get("HERDR_STUB_AGENTS", '{{"result":{{"agents":[]}}}}'))
    elif args[:2] == ["workspace", "create"]:
        print('{{"result":{{"workspace":{{"workspace_id":"W1"}},"root_pane":{{"pane_id":"p1"}}}}}}')
    elif args[:2] == ["agent", "attach"]:
        sys.exit(23)
    sys.exit(0)
sys.exit(17)
"""
LIVE = json.dumps({"result": {"agents": [
    {"agent": "claude", "agent_session": {"value": "synthetic-live"}, "pane_id": "pane-7"}]}})
failures = []


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'}: {name}{'' if ok else ': ' + detail}")
    if not ok:
        failures.append(name)


def records(capture):
    return [json.loads(line) for line in capture.read_text().splitlines()] if capture.exists() else []


def main():
    hm_functions = Path(sys.argv[1])
    with tempfile.TemporaryDirectory(prefix="claude-bypass-dispatch-") as tmp:
        root = Path(tmp)
        capture = root / "capture.jsonl"
        bindir = root / "bin"
        bindir.mkdir()
        for tool in ("claude", "herdr"):
            stub = bindir / tool
            stub.write_text(STUB.format(python=sys.executable, tool=tool))
            stub.chmod(0o700)
        token = root / "otlp-token"
        token.write_text("synthetic-otlp-token\n")
        functions = root / "functions"
        functions.mkdir()
        for name in ("claude.fish", "claude-bypass.fish"):
            text = (hm_functions / name).read_text().replace("/run/secrets/native_otlp_auth", str(token))
            (functions / name).write_text(text)
        if "herdr-agent-launcher" not in (functions / "claude.fish").read_text():
            raise SystemExit("claude.fish does not dispatch through the Herdr launcher; stubs would be bypassed")
        suffix = re.search(r"claude \$argv (--settings \S+ --dangerously-skip-permissions)$",
                           (functions / "claude-bypass.fish").read_text(), re.M)
        if not suffix:
            raise SystemExit("unexpected claude-bypass body")
        suffix = suffix.group(1).split()
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("HERDR_", "SSH_", "OTEL_")) and k != "CI"}
        env.update(STUB_CAPTURE=str(capture), PATH=f"{bindir}:{env['PATH']}",
                   # A dispatch that bypasses the stubs reaches a dead port, never the API.
                   ANTHROPIC_API_KEY="synthetic-key", ANTHROPIC_BASE_URL="http://127.0.0.1:9",
                   CLAUDE_CONFIG_DIR=str(root / "config"))
        env.pop("CLAUDE_CODE_OAUTH_TOKEN", None)

        def fish(args, stdin=None):
            capture.unlink(missing_ok=True)
            quoted = " ".join("'" + a.replace("'", "\\'") + "'" for a in args)
            script = f"set -p fish_function_path {functions}\nclaude-bypass {quoted}"
            p = subprocess.run(["fish", "--no-config", "-c", script], env=env, cwd=root,
                               input=stdin or "", capture_output=True, text=True, timeout=60)
            return p.returncode, p.stderr, records(capture)

        # A + B: the real HM functions, non-TTY so the launcher runs the client natively.
        for args in ([], ["--version", "argument with spaces"], ["--resume", "synthetic-id"],
                     ["fix the --settings parser"]):
            status, err, calls = fish(args)
            check(f"dispatch once: {args}",
                  status == 17 and len(calls) == 1 and calls[0]["args"] == args + suffix
                  and calls[0]["has_header"], f"status={status} calls={calls} err={err[-200:]}")
        # Zero arguments must not read stdin as candidate arguments.
        status, err, calls = fish([], stdin="--settings\n")
        check("zero args with '--settings' on stdin still dispatches",
              status == 17 and len(calls) == 1 and calls[0]["args"] == suffix, f"status={status} calls={calls}")
        for args in (["--"], ["--", "prompt"], ["--settings", "x.json"], ["--settings=x.json"],
                     ["--permission-mode", "plan"], ["--permission-mode=default"]):
            status, err, calls = fish(args)
            check(f"reject {args}", status == 2 and not calls and "claude-bypass:" in err,
                  f"status={status} calls={calls} err={err[-200:]}")

        # C: Herdr resume/attach through the launcher under a pseudo-terminal.
        def launcher(args, agents=None):
            capture.unlink(missing_ok=True)
            cmd = shlex.join(["bash", str(LAUNCHER), "claude", *args])
            run_env = dict(env, HERDR_STUB_AGENTS=agents or '{"result":{"agents":[]}}')
            p = subprocess.run(["script", "-qec", cmd, "/dev/null"], env=run_env, cwd=root,
                               stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
            return p.returncode, p.stdout, [(c["tool"], c["args"]) for c in records(capture)]

        for form in (["--resume", "synthetic-live"], ["-r", "synthetic-live"], ["--resume=synthetic-live"]):
            status, out, calls = launcher(form + suffix, LIVE)
            check(f"bypass {form[0]} of a live pane is refused", status == 3 and "pane-7" in out
                  and "would not change its permission mode" in out
                  and calls == [("herdr", ["agent", "list"])], f"status={status} calls={calls}")
        status, out, calls = launcher(["--resume", "synthetic-new"] + suffix)
        check("bypass resume without a pane starts a new bypass agent",
              status == 23 and ("herdr", ["agent", "start", "cli-claude-w1", "--kind", "claude",
                                          "--pane", "p1", "--", "--resume", "synthetic-new"] + suffix) in calls
              and calls[-1] == ("herdr", ["agent", "attach", "cli-claude-w1"])
              and not any(t == "claude" for t, _ in calls), f"status={status} calls={calls}")
        status, out, calls = launcher(["--resume", "synthetic-live"], LIVE)
        check("plain resume still attaches the live pane",
              status == 23 and calls == [("herdr", ["agent", "list"]), ("herdr", ["agent", "attach", "pane-7"])],
              f"status={status} calls={calls}")
        status, out, calls = launcher(["doctor"] + suffix)
        check("bypass subcommand runs natively once",
              status == 17 and calls == [("claude", ["doctor"] + suffix)], f"status={status} calls={calls}")
    if failures:
        raise SystemExit(f"{len(failures)} failure(s)")


if __name__ == "__main__":
    main()
