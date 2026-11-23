"""Fake Alloy for the runtime harness's exit-status oracle, never a filter implementation."""
import http.server
import json
import pathlib
import re
import signal
import sys

if sys.argv[1] == "validate":
    sys.exit(0)

config = pathlib.Path(sys.argv[-1]).read_text()
port = int(re.search(r"listen_port\s*=\s*(\d+)", config)[1])


class Receiver(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        for stream in payload["streams"]:
            for _, line in stream["values"]:
                if "test_case=keep_" in line:
                    print(line, flush=True)
        self.send_response(204)
        self.end_headers()

    def log_message(self, *_):
        pass


def fail_shutdown(*_):
    raise SystemExit(2)


signal.signal(signal.SIGTERM, fail_shutdown)
with http.server.HTTPServer(("127.0.0.1", port), Receiver) as server:
    server.serve_forever()
