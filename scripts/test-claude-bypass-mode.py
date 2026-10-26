#!/usr/bin/env python3
"""Ordinary sessions stay scrubbed; the claude-bypass settings layer reaches
bypassPermissions without handing the OTLP credential to subprocesses.

usage: test-claude-bypass-mode.py <generated settings.json> <claude-bypass.fish>

Runs the real claude binary against a local mock API and OTLP receiver with
fake credentials; no paid request, no hooks, nothing leaves 127.0.0.1.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FAKE_OTLP = "BYPASS_TEST_FAKE_OTLP_TOKEN"
FAKE_KEY = "BYPASS_TEST_FAKE_ANTHROPIC_KEY"
# Credential-shaped: withheld from subprocesses only while scrubbing is on.
FAKE_AWS = "BYPASS_TEST_FAKE_AWS_SECRET"
# Read-only Bash runs in every mode, so it checks the subprocess env; the
# Write tool needs a grant in default mode, so it shows the effective mode.
COMMAND = "printenv OTEL_EXPORTER_OTLP_HEADERS AWS_SECRET_ACCESS_KEY"


def sse(model, block, delta, stop_reason):
    message = {
        "id": "msg_test", "type": "message", "role": "assistant", "model": model,
        "content": [], "stop_reason": None, "stop_sequence": None,
        "usage": {"input_tokens": 1, "output_tokens": 1},
    }
    return [
        ("message_start", {"type": "message_start", "message": message}),
        ("content_block_start", {"type": "content_block_start", "index": 0, "content_block": block}),
        ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": delta}),
        ("content_block_stop", {"type": "content_block_stop", "index": 0}),
        ("message_delta", {"type": "message_delta",
                           "delta": {"stop_reason": stop_reason, "stop_sequence": None},
                           "usage": {"output_tokens": 1}}),
        ("message_stop", {"type": "message_stop"}),
    ]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if self.path.startswith("/v1/metrics") or self.path.startswith("/v1/logs"):
            self.server.otlp_auth.append(self.headers.get("Authorization", ""))
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if not self.path.startswith("/v1/messages"):
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        request = json.loads(body)
        model = request.get("model", "claude-opus-5-5")
        results = self.tool_results(request.get("messages", []))
        if not results:
            events = self.tool_use("Bash", {"command": COMMAND}, model)
        elif len(results) == 1:
            events = self.tool_use("Write", {"file_path": self.server.write_probe, "content": "probe\n"}, model)
        else:
            self.server.results = results
            events = sse(model, {"type": "text", "text": ""}, {"type": "text_delta", "text": "done"}, "end_turn")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        for event, payload in events:
            self.wfile.write(f"event: {event}\ndata: {json.dumps(payload)}\n\n".encode())
        self.close_connection = True

    @staticmethod
    def tool_use(name, tool_input, model):
        return sse(model, {"type": "tool_use", "id": f"toolu_{name}", "name": name, "input": {}},
                   {"type": "input_json_delta", "partial_json": json.dumps(tool_input)}, "tool_use")

    @staticmethod
    def tool_results(messages):
        results = []
        for message in messages:
            content = message.get("content", [])
            for block in content if isinstance(content, list) else []:
                if block.get("type") == "tool_result":
                    raw = block.get("content", "")
                    text = raw if isinstance(raw, str) else "".join(i.get("text", "") for i in raw)
                    seen = [n for n, v in (("otlp", FAKE_OTLP), ("aws", FAKE_AWS)) if v in text]
                    # printenv exits 1 when a variable is absent.
                    if not seen and block.get("is_error") and text.strip() != "Exit code 1":
                        results.append("DENIED")
                    else:
                        results.append("+".join(seen) or "none")
        return results

    def log_message(self, *args):
        return


def run_case(claude, settings, extra_args, workdir):
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.results = []
    server.otlp_auth = []
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{server.server_port}"
    try:
        config_dir = Path(tempfile.mkdtemp(dir=workdir))
        server.write_probe = str(config_dir / "write-probe")
        user = json.loads(Path(settings).read_text())
        user.pop("hooks", None)
        # The real allow list grants Write, which would hide the effective mode.
        user.get("permissions", {}).pop("allow", None)
        env_block = user.setdefault("env", {})
        if "OTEL_EXPORTER_OTLP_ENDPOINT" in env_block:
            env_block["OTEL_EXPORTER_OTLP_ENDPOINT"] = base
            env_block["OTEL_METRIC_EXPORT_INTERVAL"] = "500"
        (config_dir / "settings.json").write_text(json.dumps(user))
        (config_dir / ".claude.json").write_text(
            json.dumps({"hasCompletedOnboarding": True, "bypassPermissionsModeAccepted": True}))
        environment = {k: v for k, v in os.environ.items()
                       if not k.startswith(("ANTHROPIC_", "AWS_", "CLAUDE", "OTEL_"))}
        environment.update({
            "ANTHROPIC_API_KEY": FAKE_KEY,
            "ANTHROPIC_BASE_URL": base,
            "AWS_SECRET_ACCESS_KEY": FAKE_AWS,
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "CLAUDE_CONFIG_DIR": str(config_dir),
            "DISABLE_AUTOUPDATER": "1",
            # What the Fish telemetry prelude injects for every claude launch.
            "OTEL_EXPORTER_OTLP_HEADERS": f"Authorization=Bearer {FAKE_OTLP}",
        })
        try:
            result = subprocess.run(
                [claude, "-p", "Run the Bash command.", "--tools", "Bash,Write",
                 "--allowedTools", f"Bash({COMMAND})", "--output-format", "stream-json",
                 "--verbose", "--setting-sources", "user", *extra_args],
                env=environment, cwd=config_dir, stdin=subprocess.DEVNULL,
                capture_output=True, text=True, timeout=90, check=False,
            )
        except subprocess.TimeoutExpired:
            return None, None, None, [], "timed out after 90s"
        mode = next((json.loads(line).get("permissionMode") for line in result.stdout.splitlines()
                     if '"subtype":"init"' in line), None)
        stderr = result.stderr
        for secret in (FAKE_OTLP, FAKE_KEY, FAKE_AWS):
            stderr = stderr.replace(secret, "<fake>")
        bash = server.results[0] if server.results else None
        write = "WROTE" if os.path.exists(server.write_probe) else "DENIED"
        return mode, bash, write, list(server.otlp_auth), stderr
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def main():
    settings, function_file = sys.argv[1], sys.argv[2]
    claude = os.environ.get("CLAUDE_BIN") or shutil.which("claude")
    if not claude:
        raise SystemExit("claude executable not found")
    # Pins the generated function body, which the Herdr launcher's suffix match depends on.
    body = re.search(r"^\s*claude \$argv --settings (\S+) --dangerously-skip-permissions$",
                     Path(function_file).read_text(), re.M)
    if not body:
        raise SystemExit(f"unexpected claude-bypass body in {function_file}")
    bypass = ["--settings", body.group(1), "--dangerously-skip-permissions"]
    failures = []
    with tempfile.TemporaryDirectory(prefix="claude-bypass-test-") as workdir:
        cases = [
            ("ordinary", [], "default", "none", "DENIED"),
            # Pins the upstream downgrade: when this fails, claude-bypass may be unnecessary.
            ("ordinary --dangerously-skip-permissions", ["--dangerously-skip-permissions"],
             "default", "none", "DENIED"),
            ("claude-bypass", bypass, "bypassPermissions", "aws", "WROTE"),
        ]
        for name, args, want_mode, want_env, want_write in cases:
            mode, bash, write, otlp, stderr = run_case(claude, settings, args, workdir)
            otlp_ok = bool(otlp) and all(a == f"Bearer {FAKE_OTLP}" for a in otlp)
            ok = mode == want_mode and bash == want_env and write == want_write and otlp_ok
            print(f"{'PASS' if ok else 'FAIL'}: {name}: mode={mode} child_env={bash} "
                  f"write={write} otlp_exports={len(otlp)} otlp_auth={'ok' if otlp_ok else 'WRONG'}")
            if not ok:
                failures.append(f"{name}: {stderr[-400:]!r}")
    if failures:
        raise SystemExit("\n".join(failures))


if __name__ == "__main__":
    main()
