"""ollama-pull-pinned against a stub Ollama API with the real ollama CLI: a tag at its pin is not pulled, an absent
tag is pulled, and a moved tag is pulled, removed again and exits 3, so an unpinned model is never left served."""
import http.server
import json
import os
import subprocess
import sys
import threading

SCRIPT = "modules/homelab/ollama-pull-pinned.sh"
A, B = "a" * 64, "b" * 64
failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


class Registry(http.server.BaseHTTPRequestHandler):
    tags, serves, calls = {}, {}, []

    def reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def do_HEAD(self):
        self.send_response(200)
        self.end_headers()

    def do_GET(self):
        if self.path == "/api/tags":
            return self.reply(200, {"models": [{"name": n, "digest": d} for n, d in self.tags.items()]})
        self.reply(404, {"error": "not found"})

    def do_POST(self):
        req = self.body()
        name = req.get("model") or req.get("name")
        if self.path == "/api/pull":
            self.calls.append(("pull", name))
            self.tags[name] = self.serves[name]
            return self.reply(200, {"status": "success"})
        if self.path == "/api/generate" and name not in self.tags:
            return self.reply(404, {"error": f"model '{name}' not found"})
        self.reply(200, {"done": True})

    def do_DELETE(self):
        req = self.body()
        name = req.get("model") or req.get("name")
        self.calls.append(("rm", name))
        if self.tags.pop(name, None) is None:
            return self.reply(404, {"error": f"model '{name}' not found"})
        self.reply(200, {})

    def log_message(self, *a):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Registry)
threading.Thread(target=server.serve_forever, daemon=True).start()
env = dict(os.environ, OLLAMA_HOST=f"127.0.0.1:{server.server_address[1]}", HOME=os.environ.get("TMPDIR", "/tmp"))


def run(tags, serves, pins):
    Registry.tags, Registry.serves, Registry.calls = dict(tags), serves, []
    p = subprocess.run(["bash", "-euo", "pipefail", SCRIPT, *[f"{n} {d}" for n, d in pins]],
                       env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return p.returncode, p.stderr, Registry.calls, Registry.tags


rc, err, calls, tags = run({"m:t": A}, {"m:t": B}, [("m:t", A)])
check(rc == 0 and calls == [], f"a tag at its pin is not pulled, even when the registry moved (rc {rc}, {calls})")

rc, err, calls, tags = run({}, {"m:t": A}, [("m:t", A)])
check(rc == 0 and calls == [("pull", "m:t")] and tags == {"m:t": A},
      f"an absent tag is pulled once and kept (rc {rc}, {calls}, {tags})")

rc, err, calls, tags = run({}, {"m:t": B}, [("m:t", A)])
check(rc == 3 and calls == [("pull", "m:t"), ("rm", "m:t")] and "m:t" not in tags
      and f"served {B}, pinned is {A}" in err,
      f"a moved tag is pulled, removed again and exits 3 (rc {rc}, {calls}, {tags}, {err.strip()!r})")

rc, err, calls, tags = run({"x:y": B}, {"m:t": B, "x:y": A}, [("m:t", A), ("x:y", A)])
check(rc == 3 and tags == {"x:y": A} and calls == [("pull", "m:t"), ("rm", "m:t"), ("pull", "x:y")],
      f"a moved tag does not stop the next pin, and a tag off its pin is pulled back to it (rc {rc}, {calls}, {tags})")

server.shutdown()
sys.exit(1 if failed else 0)
