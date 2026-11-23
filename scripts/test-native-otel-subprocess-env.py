#!/usr/bin/env python3
import json
import os
import shutil
import sys
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


COMMAND = "printenv OTEL_EXPORTER_OTLP_HEADERS"
STABLE_SHELL = "/run/current-system/sw/bin/bash"


class MockMessagesHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        if self.path.startswith(("/v1/metrics", "/v1/logs")):
            self.server.otlp_auth.append(self.headers.get("Authorization", ""))
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        request = json.loads(body)
        model = request.get("model", "claude-opus-5-5")
        server = self.server
        if server.issued:
            server.results.append(self.find_tool_result(request.get("messages", [])))
        if server.issued < len(server.commands):
            if server.issued:
                server.between_calls()
            response = self.tool_response(model, server.issued, server.commands[server.issued])
            server.issued += 1
        else:
            response = self.text_response(model, "done")

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        for event, payload in response:
            self.wfile.write(f"event: {event}\ndata: {json.dumps(payload)}\n\n".encode())
        self.wfile.flush()
        self.close_connection = True

    def find_tool_result(self, messages):
        for message in reversed(messages):
            for block in message.get("content", []):
                if block.get("type") == "tool_result":
                    content = block.get("content", "")
                    if isinstance(content, str):
                        return content
                    return "".join(item.get("text", "") for item in content)
        return ""

    def tool_response(self, model, index, command):
        message = {
            "id": f"msg_test_tool_{index}",
            "type": "message",
            "role": "assistant",
            "model": model,
            "content": [],
            "stop_reason": None,
            "stop_sequence": None,
            "usage": {"input_tokens": 1, "output_tokens": 1},
        }
        command = json.dumps({"command": command})
        return [
            ("message_start", {"type": "message_start", "message": message}),
            (
                "content_block_start",
                {
                    "type": "content_block_start",
                    "index": 0,
                    "content_block": {
                        "type": "tool_use",
                        "id": f"toolu_test_{index}",
                        "name": "Bash",
                        "input": {},
                    },
                },
            ),
            (
                "content_block_delta",
                {
                    "type": "content_block_delta",
                    "index": 0,
                    "delta": {"type": "input_json_delta", "partial_json": command},
                },
            ),
            ("content_block_stop", {"type": "content_block_stop", "index": 0}),
            (
                "message_delta",
                {
                    "type": "message_delta",
                    "delta": {"stop_reason": "tool_use", "stop_sequence": None},
                    "usage": {"output_tokens": 1},
                },
            ),
            ("message_stop", {"type": "message_stop"}),
        ]

    def text_response(self, model, text):
        message = {
            "id": "msg_test_result",
            "type": "message",
            "role": "assistant",
            "model": model,
            "content": [],
            "stop_reason": None,
            "stop_sequence": None,
            "usage": {"input_tokens": 1, "output_tokens": 1},
        }
        return [
            ("message_start", {"type": "message_start", "message": message}),
            (
                "content_block_start",
                {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}},
            ),
            (
                "content_block_delta",
                {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text}},
            ),
            ("content_block_stop", {"type": "content_block_stop", "index": 0}),
            (
                "message_delta",
                {
                    "type": "message_delta",
                    "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                    "usage": {"output_tokens": 1},
                },
            ),
            ("message_stop", {"type": "message_stop"}),
        ]

    def log_message(self, format_string, *args):
        return


def run_case(claude, settings, extra_args, commands=(COMMAND,), between_calls=lambda: None, extra_env=None):
    server = ThreadingHTTPServer(("127.0.0.1", 0), MockMessagesHandler)
    server.commands = list(commands)
    server.between_calls = between_calls
    server.issued = 0
    server.results = []
    server.otlp_auth = []
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="claude-otel-env-test-") as config_dir:
            # The generated settings, minus hooks (they reach Herdr) and with
            # telemetry pointed at the mock instead of the real receiver.
            generated = json.loads(open(settings).read())
            generated.pop("hooks", None)
            generated["env"]["OTEL_EXPORTER_OTLP_ENDPOINT"] = f"http://127.0.0.1:{server.server_port}"
            generated["env"]["OTEL_METRIC_EXPORT_INTERVAL"] = "500"
            with open(os.path.join(config_dir, "settings.json"), "w") as out:
                json.dump(generated, out)
            environment = os.environ.copy()
            for name in (
                "ANTHROPIC_AUTH_TOKEN",
                "ANTHROPIC_CUSTOM_HEADERS",
                "ANTHROPIC_FOUNDRY_AUTH_TOKEN",
                "ANTHROPIC_API_KEY",
                "CLAUDE_CODE_OAUTH_TOKEN",
            ):
                environment.pop(name, None)
            environment.update(
                {
                    "ANTHROPIC_API_KEY": "NATIVE_OTLP_FAKE_ANTHROPIC_KEY",
                    "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{server.server_port}",
                    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
                    "CLAUDE_CODE_SIMPLE": "1",
                    "CLAUDE_CONFIG_DIR": config_dir,
                    "DISABLE_AUTOUPDATER": "1",
                    "OTEL_EXPORTER_OTLP_HEADERS": "Authorization=Bearer NATIVE_OTLP_FAKE_TOKEN",
                }
            )
            environment.pop("CLAUDE_CODE_SUBPROCESS_ENV_SCRUB", None)
            environment.pop("CLAUDE_CODE_SHELL", None)
            environment.update(extra_env or {})
            result = subprocess.run(
                [
                    claude,
                    "-p",
                    "Use Bash once to check whether OTEL_EXPORTER_OTLP_HEADERS is present. Reply with only CLEAN or LEAKED.",
                    "--tools",
                    "Bash",
                    "--allowedTools",
                    *(f"Bash({command})" for command in commands),
                    "--output-format",
                    "stream-json",
                    "--verbose",
                    *extra_args,
                ],
                env=environment,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=90,
                check=False,
            )
        mode = next((json.loads(line).get("permissionMode") for line in result.stdout.splitlines()
                     if '"subtype":"init"' in line), None)
        authorized = bool(server.otlp_auth) and all(
            a == "Bearer NATIVE_OTLP_FAKE_TOKEN" for a in server.otlp_auth)
        output = f"{result.stdout[-300:]}\n{result.stderr}"
        output = output.replace("NATIVE_OTLP_FAKE_TOKEN", "<fake-token>")
        output = output.replace("NATIVE_OTLP_FAKE_ANTHROPIC_KEY", "<fake-key>")
        return mode, server.results, authorized, output.strip()
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def shell_case(claude, settings):
    """Two Bash calls; between them the shell the session would detect at start goes away, as a switch to a
    generation whose Home Manager profile no longer carries it does."""
    configured = json.loads(open(settings).read())["env"].get("CLAUDE_CODE_SHELL")
    with tempfile.TemporaryDirectory(prefix="claude-shell-test-") as profile:
        detected = os.path.join(profile, "bash")
        os.symlink(os.path.realpath(shutil.which("bash")), detected)
        _, results, _, output = run_case(
            claude, settings, [], commands=("echo first-ok", "echo second-ok"),
            between_calls=lambda: os.unlink(detected), extra_env={"SHELL": detected})
    return configured, [r.strip() for r in results], output


def main():
    settings = sys.argv[1]
    claude = os.environ.get("CLAUDE_BIN") or shutil.which("claude")
    if not claude:
        raise SystemExit("claude executable not found")
    generated = json.loads(open(settings).read())
    assert generated.get("enableArtifact") is False, "enableArtifact must be false"
    failures = 0
    for name, args, want in [("claude", [], "default"),
                             ("claude --dangerously-skip-permissions",
                              ["--dangerously-skip-permissions"], "bypassPermissions")]:
        mode, results, authorized, output = run_case(claude, settings, args)
        result = ("LEAKED" if "NATIVE_OTLP_FAKE_TOKEN" in results[0] else "CLEAN") if results else None
        ok = mode == want and result == "CLEAN" and authorized
        print(f"{'PASS' if ok else 'FAIL (scripts/test-native-otel-subprocess-env.py)'}: {name}: mode={mode} bash_otlp_header={result} "
              f"otlp_export_authorized={authorized}")
        if not ok:
            failures += 1
            print(output[-500:])
    configured, results, output = shell_case(claude, settings)
    ok = configured == STABLE_SHELL and results == ["first-ok", "second-ok"]
    print(f"{'PASS' if ok else 'FAIL (scripts/test-native-otel-subprocess-env.py)'}: Bash after the session's "
          f"startup shell path is gone: CLAUDE_CODE_SHELL={configured} results={results}")
    if not ok:
        failures += 1
        print(output[-500:])
    if failures:
        raise SystemExit(f"{failures} case(s) failed")


if __name__ == "__main__":
    main()
