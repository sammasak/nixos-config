#!/usr/bin/env python3
"""A pool slot's git pushes, held to its own task's refs (docs/records/execution-pool-credentials.md, slice 3).

The slot's Caddy site sends every git-receive-pack request here with X-Pool-Slot set to the slot's name, overriding any
the guest sent. The filter reads the ref updates at the head of the body (pkt-lines, up to the first flush) and passes
the request on unchanged, to the host's push site (UPSTREAM, a Caddy socket that signs it), only when every update is to
`refs/heads/pool/<id>` or `refs/pool-wip/<id>`, `<id>` being the task id in that slot's manifest (SLOTS maps each slot
to its file, the runner's). Anything else, or anything it cannot read, is a 403 before a byte reaches GitHub.

GitHub's own answer is passed back as it comes, so the client sees whether the push landed. A broken upstream is a 502
and nothing is tried again: the push may or may not have landed, and only the client (the park checks with ls-remote)
decides what to do.

Usage: exec-pool-push-filter LISTEN UPSTREAM SLOTS"""

import http.client
import http.server
import json
import os
import re
import socket
import socketserver
import sys
from collections.abc import Iterator
import io

REPO_PATH = re.compile(r"/(?!\.)[A-Za-z0-9_.-]+/(?!\.)[A-Za-z0-9_.-]+/git-receive-pack")
# agent::branch in pkgs/exec-pool/src/agent.rs
TASK_ID = re.compile(r"(?!-)[A-Za-z0-9_-]{1,100}")
OID = "(?:[0-9a-f]{40}|[0-9a-f]{64})"
UPDATE = re.compile(rf"{OID} {OID} (refs/[^\x00 ]+)")
SHALLOW = re.compile(rf"shallow {OID}")
# the commands of one push, never its pack: a push of more refs than this is no task's
MAX_COMMANDS = 64
CHUNK = 65536
PASSED = ("Content-Type", "Accept", "Accept-Encoding", "Accept-Language", "Git-Protocol", "User-Agent", "Host")
RETURNED = ("Content-Type", "Content-Encoding", "Cache-Control", "Expires", "Pragma")


class Refused(Exception):
    pass


class Body:
    """The request body as sent, decoded from Content-Length or chunked transfer coding."""

    def __init__(self, rfile: io.BufferedIOBase, length: int | None) -> None:
        self.rfile = rfile
        self.left = length
        self.chunked = length is None
        self.done = length == 0

    def read(self, n: int) -> bytes:
        """At most n bytes, fewer only at the end."""
        out = b""
        while len(out) < n and not self.done:
            if self.chunked and not self.left:
                size = self.rfile.readline(1024).split(b";", 1)[0].strip()
                if not re.fullmatch(rb"[0-9a-fA-F]{1,8}", size):
                    raise Refused("a malformed chunk")
                self.left = int(size, 16)
                if self.left == 0:
                    while self.rfile.readline(1024) not in (b"\r\n", b"\n", b""):
                        pass
                    self.done = True
                    break
            want = min(n - len(out), self.left or 0)
            got = self.rfile.read(want)
            if not got:
                raise Refused("the body ended early")
            out += got
            self.left = (self.left or 0) - len(got)
            if self.left == 0:
                if self.chunked:
                    self.rfile.readline(1024)
                else:
                    self.done = True
        return out

    def exact(self, n: int) -> bytes:
        got = self.read(n)
        if len(got) != n:
            raise Refused("the body ended inside a pkt-line")
        return got


def updates(body: Body) -> tuple[list[str], bytes]:
    """The refs the push updates, and the bytes read to find them."""
    head = b""
    refs: list[str] = []
    first = True
    while True:
        size = body.exact(4)
        head += size
        if not re.fullmatch(rb"[0-9a-f]{4}", size):
            raise Refused(f"no pkt-line length: {size!r}")
        n = int(size, 16)
        if n == 0:
            return refs, head
        if n < 5:
            raise Refused(f"pkt-line length {n} in the commands")
        line = body.exact(n - 4)
        head += line
        text = line.split(b"\x00", 1)[0] if first else line
        first = False
        cmd = text.rstrip(b"\n").decode("utf-8", "replace")
        if SHALLOW.fullmatch(cmd):
            continue
        m = UPDATE.fullmatch(cmd)
        if m is None:
            raise Refused(f"not a ref update: {cmd[:80]!r}")
        refs.append(m.group(1))
        if len(refs) > MAX_COMMANDS:
            raise Refused("too many ref updates")


def own_refs(manifest: str) -> set[str]:
    try:
        with open(manifest, encoding="utf-8") as f:
            task_id = json.load(f)["task"]["id"]
    except (OSError, ValueError, KeyError, TypeError) as e:
        raise Refused(f"no task in {manifest}: {e}") from e
    if not isinstance(task_id, str) or not TASK_ID.fullmatch(task_id):
        raise Refused(f"task id {task_id!r}")
    return {f"refs/heads/pool/{task_id}", f"refs/pool-wip/{task_id}"}


class UnixConnection(http.client.HTTPConnection):
    def __init__(self, path: str) -> None:
        super().__init__("localhost", timeout=600)
        self.path = path

    def connect(self) -> None:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        s.connect(self.path)
        self.sock = s


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    upstream = ""
    slots: dict[str, str] = {}

    def address_string(self) -> str:
        return "caddy"

    def log_message(self, format: str, *args: object) -> None:
        pass

    def note(self, what: str) -> None:
        print(f"{what} slot={self.headers.get('X-Pool-Slot')!r} path={self.path!r}", file=sys.stderr, flush=True)

    def refuse(self, why: str) -> None:
        self.note(f"refused ({why})")
        msg = f"push refused by the pool's ref filter: {why}\n".encode()
        self.close_connection = True
        self.send_response(403)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(msg)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(msg)

    def do_POST(self) -> None:
        try:
            self.filter()
        except Refused as e:
            self.refuse(str(e))

    def do_GET(self) -> None:
        self.refuse("only a git-receive-pack POST is filtered")

    def filter(self) -> None:
        slot = self.headers.get("X-Pool-Slot", "")
        if slot not in self.slots:
            raise Refused("no such slot")
        if not REPO_PATH.fullmatch(self.path):
            raise Refused("not a repository's git-receive-pack")
        if self.headers.get("Content-Encoding", "identity").strip().lower() != "identity":
            raise Refused("a compressed body")
        te = self.headers.get("Transfer-Encoding", "").strip().lower()
        cl = self.headers.get("Content-Length")
        if te not in ("", "chunked") or (te == "chunked" and cl is not None):
            raise Refused("an unknown framing")
        if te == "" and (cl is None or not cl.isdigit()):
            raise Refused("no length")
        body = Body(self.rfile, None if te == "chunked" else int(cl or "0"))
        allowed = own_refs(self.slots[slot])
        refs, head = updates(body)
        wrong = [r for r in refs if r not in allowed]
        if wrong:
            raise Refused(f"{', '.join(wrong)}: a slot pushes only {' and '.join(sorted(allowed))}")
        self.note(f"passed {refs}")
        self.forward(head, body)

    def forward(self, head: bytes, body: Body) -> None:
        def rest() -> Iterator[bytes]:
            yield head
            while chunk := body.read(CHUNK):
                yield chunk

        headers = {h: v for h in PASSED if (v := self.headers.get(h)) is not None}
        conn = UnixConnection(self.upstream)
        try:
            conn.request("POST", self.path, body=rest(), headers=headers, encode_chunked=True)
            resp = conn.getresponse()
        except (OSError, http.client.HTTPException, Refused) as e:
            self.note(f"upstream failed ({e})")
            self.close_connection = True
            self.send_response(502)
            self.send_header("Content-Length", "0")
            self.send_header("Connection", "close")
            self.end_headers()
            conn.close()
            return
        self.send_response(resp.status, resp.reason)
        for h in RETURNED:
            if (v := resp.getheader(h)) is not None:
                self.send_header(h, v)
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        try:
            while chunk := resp.read(CHUNK):
                self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
            self.wfile.write(b"0\r\n\r\n")
        except (OSError, http.client.HTTPException) as e:
            # the status is sent: a cut body is what the client sees, and it decides
            self.note(f"upstream cut ({e})")
            self.close_connection = True
        finally:
            conn.close()


class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True

    def handle_error(self, request: object, client_address: object) -> None:
        print(f"request failed: {sys.exc_info()[1]!r}", file=sys.stderr, flush=True)


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    listen, Handler.upstream = argv[1], argv[2]
    with open(argv[3], encoding="utf-8") as f:
        Handler.slots = json.load(f)
    if os.path.exists(listen):
        os.unlink(listen)
    # Caddy runs as this user: no other reaches the socket
    os.umask(0o077)
    with Server(listen, Handler) as server:
        server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
