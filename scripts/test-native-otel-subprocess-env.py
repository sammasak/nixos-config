#!/usr/bin/env python3
import json
import os
import shutil
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


COMMAND = "printenv OTEL_EXPORTER_OTLP_HEADERS"


class MockMessagesHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        self.server.request_count += 1
        length = int(self.headers.get("Content-Length", "0"))
        request = json.loads(self.rfile.read(length))
        if not self.server.tool_requested:
            self.server.tool_requested = True
            response = self.tool_response(request.get("model", "claude-opus-5-5"))
        else:
            self.server.tool_result = self.find_tool_result(request.get("messages", []))
            result = self.server.tool_result
            text = "CLEAN" if result == "CLEAN" else "LEAKED"
            response = self.text_response(request.get("model", "claude-opus-5-5"), text)

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
                        text = content
                    else:
                        text = "".join(item.get("text", "") for item in content)
                    return "LEAKED" if "NATIVE_OTLP_FAKE_TOKEN" in text else "CLEAN"
        return ""

    def tool_response(self, model):
        message = {
            "id": "msg_test_tool",
            "type": "message",
            "role": "assistant",
            "model": model,
            "content": [],
            "stop_reason": None,
            "stop_sequence": None,
            "usage": {"input_tokens": 1, "output_tokens": 1},
        }
        command = json.dumps({"command": COMMAND})
        return [
            ("message_start", {"type": "message_start", "message": message}),
            (
                "content_block_start",
                {
                    "type": "content_block_start",
                    "index": 0,
                    "content_block": {
                        "type": "tool_use",
                        "id": "toolu_test_env",
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


def run_case(claude, scrub):
    server = ThreadingHTTPServer(("127.0.0.1", 0), MockMessagesHandler)
    server.tool_requested = False
    server.tool_result = None
    server.request_count = 0
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="claude-otel-env-test-") as config_dir:
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
                    "DISABLE_TELEMETRY": "1",
                    "OTEL_EXPORTER_OTLP_HEADERS": "Authorization=Bearer NATIVE_OTLP_FAKE_TOKEN",
                    "OTEL_LOGS_EXPORTER": "none",
                    "OTEL_METRICS_EXPORTER": "none",
                }
            )
            environment["CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"] = "1"
            result = subprocess.run(
                [
                    claude,
                    "-p",
                    "Use Bash once to check whether OTEL_EXPORTER_OTLP_HEADERS is present. Reply with only CLEAN or LEAKED.",
                    "--tools",
                    "Bash",
                    "--allowedTools",
                    "Bash(printenv OTEL_EXPORTER_OTLP_HEADERS)",
                ],
                env=environment,
                capture_output=True,
                text=True,
                timeout=45,
                check=False,
            )
        output = f"{result.stdout}\n{result.stderr}"
        output = output.replace("NATIVE_OTLP_FAKE_TOKEN", "<fake-token>")
        output = output.replace("NATIVE_OTLP_FAKE_ANTHROPIC_KEY", "<fake-key>")
        return result.returncode, server.tool_result, server.request_count, output.strip()
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def main():
    claude = os.environ.get("CLAUDE_BIN") or shutil.which("claude")
    if not claude:
        raise SystemExit("claude executable not found")
    status, result, requests, output = run_case(claude, True)
    if status != 0 or result != "CLEAN":
        raise SystemExit(
            f"subprocess environment scrub failed: exit={status}, "
            f"result={result!r}, requests={requests}, output={output[-500:]!r}"
        )
    print("PASS: Claude Bash subprocess does not receive the fake OTLP credential")


if __name__ == "__main__":
    main()
