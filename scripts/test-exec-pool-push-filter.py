#!/usr/bin/env python3
"""pkgs/exec-pool-push-filter with real git pushes: git -> Caddy (a slot site's receive-pack route, X-Pool-Slot set)
-> the filter -> Caddy's push socket -> git http-backend on a bare repository. A slot pushes its task's
`pool/<id>` and `refs/pool-wip/<id>` (a large push too, chunked), and nothing else: another branch, another task's,
a tag, a mixed push, a push with no manifest, an unknown slot and an unreadable body leave the remote as it was.
Usage: test-exec-pool-push-filter.py FILTER   (caddy and git on PATH)"""

import http.client
import http.server
import json
import os
import pathlib
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

from gate_probe import check, finish

FILTER = os.path.abspath(sys.argv[1])
GIT_ENV = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0",
           "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}


def git(*args, cwd=None):
    return subprocess.run(["git", *args], cwd=cwd, env=GIT_ENV, capture_output=True, text=True)


class Backend(http.server.BaseHTTPRequestHandler):
    """git http-backend as CGI over ROOT, the upstream GitHub stands for."""
    protocol_version = "HTTP/1.1"
    root = ""

    def log_message(self, *_):
        pass

    def body(self):
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            out = b""
            while (n := int(self.rfile.readline().split(b";")[0], 16)) > 0:
                out += self.rfile.read(n)
                self.rfile.readline()
            self.rfile.readline()
            return out
        return self.rfile.read(int(self.headers.get("Content-Length", "0")))

    def cgi(self, method):
        path, _, query = self.path.partition("?")
        env = {"PATH": os.environ["PATH"], "GIT_PROJECT_ROOT": self.root, "GIT_HTTP_EXPORT_ALL": "1",
               "REQUEST_METHOD": method, "PATH_INFO": path, "QUERY_STRING": query, "REMOTE_ADDR": "127.0.0.1",
               "CONTENT_TYPE": self.headers.get("Content-Type", ""), "GIT_CONFIG_NOSYSTEM": "1",
               "GIT_CONFIG_GLOBAL": "/dev/null"}
        if gp := self.headers.get("Git-Protocol"):
            env["GIT_PROTOCOL"] = gp
        data = self.body() if method == "POST" else b""
        env["CONTENT_LENGTH"] = str(len(data))
        out = subprocess.run(["git", "http-backend"], input=data, env=env, capture_output=True).stdout
        head, _, rest = out.partition(b"\r\n\r\n")
        status, headers = 200, []
        for line in head.decode().split("\r\n"):
            k, _, v = line.partition(": ")
            if k.lower() == "status":
                status = int(v.split()[0])
            elif k:
                headers.append((k, v))
        self.send_response(status)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(rest)))
        self.end_headers()
        self.wfile.write(rest)

    def do_GET(self):
        self.cgi("GET")

    def do_POST(self):
        self.cgi("POST")


def wait_for(probe, what, proc=None):
    deadline = time.monotonic() + 30
    while True:
        if proc is not None and proc.poll() is not None:
            raise SystemExit(f"{what} exited {proc.returncode}: {proc.stderr.read()[-400:]}")
        try:
            probe()
            return
        except OSError:
            if time.monotonic() > deadline:
                raise SystemExit(f"{what} did not listen within 30 s") from None
            time.sleep(0.1)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def raw(sock, slot, body, headers=None):
    """A request straight to the filter's socket, the way Caddy would send it."""
    conn = http.client.HTTPConnection("localhost", timeout=10)
    conn.sock = socket.socket(socket.AF_UNIX)
    conn.sock.connect(sock)
    h = {"Content-Type": "application/x-git-receive-pack-request", **(headers or {})}
    if slot is not None:
        h["X-Pool-Slot"] = slot
    conn.request("POST", "/o/r.git/git-receive-pack", body=body, headers=h)
    status = conn.getresponse().status
    conn.close()
    return status


def main():
    if shutil.which("caddy") is None or shutil.which("git") is None:
        raise SystemExit("caddy and git must be on PATH")
    with tempfile.TemporaryDirectory() as d:
        d = pathlib.Path(d)
        (d / "git" / "o").mkdir(parents=True)
        bare = d / "git" / "o" / "r.git"
        git("init", "--bare", "-q", str(bare))
        git("config", "http.receivepack", "true", cwd=bare)
        Backend.root = str(d / "git")
        backend = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Backend)
        threading.Thread(target=backend.serve_forever, daemon=True).start()

        manifest = d / "manifest.json"
        manifest.write_text(json.dumps({"task": {"id": "t-1"}}))
        (d / "slots.json").write_text(json.dumps({"pool1": str(manifest)}))
        fsock, push = str(d / "filter.sock"), str(d / "push.sock")
        port = free_port()
        (d / "Caddyfile").write_text(f"""{{
  admin off
  auto_https off
}}
http://127.0.0.1:{port} {{
  @receive path_regexp (?i)git-receive-pack
  handle @receive {{
    reverse_proxy unix/{fsock} {{
      header_up X-Pool-Slot pool1
      flush_interval -1
    }}
  }}
  handle {{
    reverse_proxy 127.0.0.1:{backend.server_port}
  }}
}}
http:// {{
  bind unix/{push}
  reverse_proxy 127.0.0.1:{backend.server_port} {{
    flush_interval -1
  }}
}}
""")
        caddy = subprocess.Popen(["caddy", "run", "--adapter", "caddyfile", "--config", str(d / "Caddyfile")],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        filt = subprocess.Popen([FILTER, fsock, push, str(d / "slots.json")],
                                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        try:
            wait_for(lambda: socket.create_connection(("127.0.0.1", port), 0.2).close(), "caddy", caddy)
            wait_for(lambda: socket.socket(socket.AF_UNIX).connect(push), "caddy's push socket", caddy)
            wait_for(lambda: socket.socket(socket.AF_UNIX).connect(fsock), "the filter", filt)
            run(d, f"http://127.0.0.1:{port}/o/r.git", bare, fsock, manifest)
        finally:
            filt.terminate()
            caddy.terminate()
            filt.wait(5)
            caddy.wait(5)
            backend.shutdown()
        log = filt.stderr.read() if filt.stderr else ""
        check("refused (" in log and "passed ['refs/heads/pool/t-1']" in log,
              f"the filter logs what it refused and passed ({log[-300:]!r})")
        check("passed []" in log, "the large push came as git's empty probe, then chunked")
    finish()


def run(d, url, bare, fsock, manifest):
    work = d / "work"
    git("init", "-q", str(work))
    (work / "f").write_text("one\n")
    git("add", "f", cwd=work)
    git("commit", "-qm", "one", cwd=work)

    def refs():
        return git("for-each-ref", "--format=%(refname)", cwd=bare).stdout.split()

    def push(*spec):
        return git("push", "--quiet", url, *spec, cwd=work)

    ok = push("HEAD:refs/heads/pool/t-1")
    check(ok.returncode == 0 and refs() == ["refs/heads/pool/t-1"], f"the task's own branch is pushed ({ok.stderr.strip()})")
    ok = push("+HEAD:refs/pool-wip/t-1")
    check(ok.returncode == 0 and "refs/pool-wip/t-1" in refs(), f"its snapshot ref is pushed ({ok.stderr.strip()})")
    ok = push(":refs/pool-wip/t-1")
    check(ok.returncode == 0 and "refs/pool-wip/t-1" not in refs(), f"and removed ({ok.stderr.strip()})")

    before = refs()
    for what, spec in [
        ("main", ["HEAD:refs/heads/main"]),
        ("another task's branch", ["HEAD:refs/heads/pool/t-2"]),
        ("another task's snapshot", ["HEAD:refs/pool-wip/t-2"]),
        ("a branch under the task's", ["HEAD:refs/heads/pool/t-1/x"]),
        ("a tag", ["HEAD:refs/tags/v1"]),
        ("its branch beside main", ["HEAD:refs/heads/pool/t-1", "HEAD:refs/heads/main"]),
        ("main deleted", [":refs/heads/pool/t-1", ":refs/heads/main"]),
    ]:
        if what == "its branch beside main":
            (work / "f").write_text("two\n")
            git("commit", "-qam", "two", cwd=work)
        bad = push(*spec)
        check(bad.returncode != 0 and refs() == before, f"{what} is refused and the remote is untouched ({refs()})")

    # past http.postBuffer: git probes, then sends the pack chunked
    (work / "big").write_bytes(os.urandom(3 << 20))
    git("add", "big", cwd=work)
    git("commit", "-qm", "big", cwd=work)
    ok = push("HEAD:refs/heads/pool/t-1")
    head = git("rev-parse", "HEAD", cwd=work).stdout.strip()
    landed = git("rev-parse", "refs/heads/pool/t-1", cwd=bare).stdout.strip()
    check(ok.returncode == 0 and landed == head, f"a large push to the task's branch lands ({ok.stderr.strip()[-200:]})")

    manifest.rename(manifest.with_suffix(".gone"))
    (work / "f").write_text("three\n")
    git("commit", "-qam", "three", cwd=work)
    bad = push("HEAD:refs/heads/pool/t-1")
    check(bad.returncode != 0 and git("rev-parse", "refs/heads/pool/t-1", cwd=bare).stdout.strip() == head,
          "with no manifest (no task in the slot) nothing is pushed")
    manifest.with_suffix(".gone").rename(manifest)

    upd = b"%s %s refs/heads/pool/t-1\x00 report-status\n" % (b"0" * 40, b"1" * 40)
    pkt = b"%04x%s0000" % (len(upd) + 4, upd)
    shallow = b"shallow %s\n" % (b"2" * 40)
    check(raw(fsock, "pool1", b"%04x%s" % (len(shallow) + 4, shallow) + pkt) != 403,
          "a shallow clone's push, its capabilities after the shallow line, passes the filter")
    check(raw(fsock, None, pkt) == 403 and raw(fsock, "pool9", pkt) == 403,
          "a request with no slot, or a slot the filter does not know, is refused")
    check(raw(fsock, "pool1", b"zzzz") == 403 and raw(fsock, "pool1", pkt[:10]) == 403
          and raw(fsock, "pool1", pkt, {"Content-Encoding": "gzip"}) == 403,
          "a body that is no pkt-line, a cut one and a compressed one are refused")


if __name__ == "__main__":
    main()
