#!/usr/bin/env python3
"""A pool slot's git pushes, held to its own task's refs (docs/records/execution-pool-credentials.md, slice 3).

The slot's Caddy site sends every git-receive-pack request here with X-Pool-Slot set to the slot's name, overriding any
the guest sent. The filter reads the ref updates at the head of the body (pkt-lines, up to the first flush) and passes
the request on unchanged, to the host's push site (UPSTREAM, a Caddy socket that signs it), only when every update is to
`refs/heads/pool/<id>` or `refs/pool-wip/<id>`, `<id>` being the task id in that slot's manifest (SLOTS maps each slot
to its file, the runner's). Anything else, or anything it cannot read, is a 403 before a byte reaches GitHub.

A slot's `POST /repos/<owner>/<repo>/pulls` comes here too: the pull request it opens is passed on only when its JSON
body's `head` is `pool/<id>` (or `<owner>:pool/<id>`) in that same repository; which repositories a slot reaches is the
sites' own list, not the filter's.

GitHub's own answer is passed back as it comes, so the client sees whether the push landed. A broken upstream is a 502
and nothing is tried again: the push may or may not have landed, and only the client (the park checks with ls-remote)
decides what to do.

With TEXTFILE, each slot's receive-pack requests passed and refused (a large push is two: git's empty probe first) are
counted there for node-exporter, as exec_pool_push_filter_pushes_total{slot,result}, and its pull request creations as
exec_pool_push_filter_pulls_total{slot,result}; a request naming no known slot counts as slot "unknown".

Usage: exec-pool-push-filter LISTEN UPSTREAM SLOTS [TEXTFILE]
       exec-pool-push-filter --list   (the metric names it writes)"""

import http.client
import http.server
import json
import os
import re
import socket
import socketserver
import sys
import threading
from collections.abc import Iterator
import io

REPO_PATH = re.compile(r"/(?!\.)[A-Za-z0-9_.-]+/(?!\.)[A-Za-z0-9_.-]+/git-receive-pack")
PULLS_PATH = re.compile(r"/repos/((?!\.)[A-Za-z0-9_.-]+)/((?!\.)[A-Za-z0-9_.-]+)/pulls/?", re.IGNORECASE)
# agent::branch in pkgs/exec-pool/src/agent.rs
TASK_ID = re.compile(r"(?!-)[A-Za-z0-9_-]{1,100}")
OID = "(?:[0-9a-f]{40}|[0-9a-f]{64})"
UPDATE = re.compile(rf"{OID} {OID} (refs/[^\x00 ]+)")
SHALLOW = re.compile(rf"shallow {OID}")
# the commands of one push, never its pack: a push of more refs than this is no task's
MAX_COMMANDS = 64
# a pull request's title and description, never more
MAX_PULL_BODY = 1 << 20
CHUNK = 65536
PASSED = ("Content-Type", "Accept", "Accept-Encoding", "Accept-Language", "Git-Protocol", "User-Agent", "Host",
          "X-GitHub-Api-Version")
RETURNED = ("Content-Type", "Content-Encoding", "Cache-Control", "Expires", "Pragma", "Location")
METRICS = {"push": ("exec_pool_push_filter_pushes_total",
                    "git-receive-pack requests from a pool slot the ref filter passed or refused."),
           "pull": ("exec_pool_push_filter_pulls_total",
                    "Pull request creations from a pool slot the filter passed or refused.")}
RESULTS = ("passed", "refused")


class Counts:
    """Pushes and pull requests by slot and result, rewritten whole to the textfile on every change."""

    def __init__(self, path: str | None, slots: list[str]) -> None:
        self.path = path
        self.lock = threading.Lock()
        # every series from the start, so the first refusal is an increase from 0
        self.n = {(k, s, r): 0 for k in METRICS for s in [*slots, "unknown"] for r in RESULTS}
        self.write()

    def bump(self, kind: str, slot: str, result: str) -> None:
        with self.lock:
            key = (kind, slot if (kind, slot, result) in self.n else "unknown", result)
            self.n[key] += 1
            self.write()

    def write(self) -> None:
        if self.path is None:
            return
        lines = []
        for kind, (metric, text) in METRICS.items():
            lines += [f"# HELP {metric} {text}", f"# TYPE {metric} counter"]
            lines += [f'{metric}{{slot="{s}",result="{r}"}} {v}'
                      for (k, s, r), v in sorted(self.n.items()) if k == kind]
        tmp = f"{self.path}.tmp"
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                f.write("\n".join(lines) + "\n")
            # node-exporter is another user, and the socket's umask would keep it out
            os.chmod(tmp, 0o644)
            os.replace(tmp, self.path)
        except OSError as e:
            # a lost count must not refuse a push: the metric goes stale and says so
            print(f"textfile not written: {e}", file=sys.stderr, flush=True)


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
        cmd = line.rstrip(b"\n").decode("utf-8", "replace")
        if SHALLOW.fullmatch(cmd):
            continue
        # the capabilities ride on the first update, after a shallow clone's shallow lines
        if first:
            cmd = cmd.split("\x00", 1)[0]
        first = False
        m = UPDATE.fullmatch(cmd)
        if m is None:
            raise Refused(f"not a ref update: {cmd[:80]!r}")
        refs.append(m.group(1))
        if len(refs) > MAX_COMMANDS:
            raise Refused("too many ref updates")


def task_id(manifest: str) -> str:
    try:
        with open(manifest, encoding="utf-8") as f:
            task_id = json.load(f)["task"]["id"]
    except (OSError, ValueError, KeyError, TypeError) as e:
        raise Refused(f"no task in {manifest}: {e}") from e
    if not isinstance(task_id, str) or not TASK_ID.fullmatch(task_id):
        raise Refused(f"task id {task_id!r}")
    return task_id


def own_refs(manifest: str) -> set[str]:
    task = task_id(manifest)
    return {f"refs/heads/pool/{task}", f"refs/pool-wip/{task}"}


def unique_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    # GitHub and this filter could each read a different one of two `head`s
    keys = [k for k, _ in pairs]
    if len(set(keys)) != len(keys):
        raise Refused("a key given twice")
    return dict(pairs)


def check_pull(body: bytes, owner: str, repo: str, task: str) -> None:
    """Refused unless the pull request's head is the task's branch in the repository it is opened on."""
    try:
        pr = json.loads(body, object_pairs_hook=unique_keys)
    except (ValueError, RecursionError) as e:
        raise Refused(f"not a JSON body: {e}") from e
    if not isinstance(pr, dict):
        raise Refused("not a JSON object")
    head, branch = pr.get("head"), f"pool/{task}"
    # `<owner>:<branch>` names a fork's branch: only the repository's own owner is the same repository
    who, colon, ref = head.rpartition(":") if isinstance(head, str) else ("", "", "")
    if ref != branch or colon and who.lower() != owner.lower():
        raise Refused(f"head {head!r}: a slot opens a pull request only from {branch}")
    head_repo = pr.get("head_repo")
    if head_repo is not None and (not isinstance(head_repo, str) or head_repo.lower() not in (
            repo.lower(), f"{owner}/{repo}".lower())):
        raise Refused(f"head_repo {head_repo!r}: a slot opens a pull request only from {owner}/{repo}")


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
    counts = Counts(None, [])

    def address_string(self) -> str:
        return "caddy"

    def log_message(self, format: str, *args: object) -> None:
        pass

    def note(self, what: str) -> None:
        print(f"{what} slot={self.headers.get('X-Pool-Slot')!r} path={self.path!r}", file=sys.stderr, flush=True)

    def kind(self) -> str:
        return "pull" if PULLS_PATH.fullmatch(self.path) else "push"

    def refuse(self, why: str) -> None:
        self.note(f"refused ({why})")
        kind = self.kind()
        self.counts.bump(kind, self.headers.get("X-Pool-Slot", ""), "refused")
        if kind == "pull":
            # gh prints an API error's message
            msg = json.dumps({"message": f"pull request refused by the pool's filter: {why}"}).encode()
            ctype = "application/json"
        else:
            msg = f"push refused by the pool's ref filter: {why}\n".encode()
            ctype = "text/plain"
        self.close_connection = True
        self.send_response(403)
        self.send_header("Content-Type", ctype)
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
        self.refuse("only a git-receive-pack or pull request POST is filtered")

    def filter(self) -> None:
        slot = self.headers.get("X-Pool-Slot", "")
        if slot not in self.slots:
            raise Refused("no such slot")
        pulls = PULLS_PATH.fullmatch(self.path)
        if pulls is None and not REPO_PATH.fullmatch(self.path):
            raise Refused("not a repository's git-receive-pack")
        body = self.body()
        if pulls is not None:
            data = body.read(MAX_PULL_BODY + 1)
            if len(data) > MAX_PULL_BODY:
                raise Refused("a body over 1 MiB")
            task = task_id(self.slots[slot])
            check_pull(data, pulls.group(1), pulls.group(2), task)
            self.note(f"passed a pull request from pool/{task}")
            self.counts.bump("pull", slot, "passed")
            self.forward(data, None)
            return
        allowed = own_refs(self.slots[slot])
        refs, head = updates(body)
        wrong = [r for r in refs if r not in allowed]
        if wrong:
            raise Refused(f"{', '.join(wrong)}: a slot pushes only {' and '.join(sorted(allowed))}")
        self.note(f"passed {refs}")
        self.counts.bump("push", slot, "passed")
        self.forward(head, body)

    def body(self) -> Body:
        if self.headers.get("Content-Encoding", "identity").strip().lower() != "identity":
            raise Refused("a compressed body")
        te = self.headers.get("Transfer-Encoding", "").strip().lower()
        cl = self.headers.get("Content-Length")
        if te not in ("", "chunked") or (te == "chunked" and cl is not None):
            raise Refused("an unknown framing")
        if te == "" and (cl is None or not cl.isdigit()):
            raise Refused("no length")
        return Body(self.rfile, None if te == "chunked" else int(cl or "0"))

    def forward(self, head: bytes, body: Body | None) -> None:
        """head, then the rest of body chunked; with no body, head alone with its length."""
        def rest() -> Iterator[bytes]:
            yield head
            while body is not None and (chunk := body.read(CHUNK)):
                yield chunk

        headers = {h: v for h in PASSED if (v := self.headers.get(h)) is not None}
        conn = UnixConnection(self.upstream)
        try:
            if body is None:
                conn.request("POST", self.path, body=head, headers=headers)
            else:
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
    if argv[1:] == ["--list"]:
        print("\n".join(m for m, _ in METRICS.values()))
        return 0
    if len(argv) not in (4, 5):
        print(__doc__, file=sys.stderr)
        return 2
    listen, Handler.upstream = argv[1], argv[2]
    with open(argv[3], encoding="utf-8") as f:
        Handler.slots = json.load(f)
    Handler.counts = Counts(argv[4] if len(argv) == 5 else None, list(Handler.slots))
    if os.path.exists(listen):
        os.unlink(listen)
    # Caddy runs as this user: no other reaches the socket
    os.umask(0o077)
    with Server(listen, Handler) as server:
        server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
