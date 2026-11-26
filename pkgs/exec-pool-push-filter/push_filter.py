#!/usr/bin/env python3
"""A pool slot's git pushes, held to its own task's refs (docs/records/execution-pool-credentials.md, slice 3).

The slot's Caddy site sends every git-receive-pack request here with X-Pool-Slot set to the slot's name, overriding any
the guest sent. The filter reads the ref updates at the head of the body (pkt-lines, up to the first flush) and passes
the request on unchanged, to the host's push site (UPSTREAM, a Caddy socket that signs it), only when every update is to
`refs/heads/pool/<id>` or `refs/pool-wip/<id>`, `<id>` being the task id in that slot's manifest (SLOTS maps each slot
to its file, the runner's). Anything else, or anything it cannot read, is a 403 before a byte reaches GitHub.

A slot's `POST /repos/<owner>/<repo>/pulls` comes here too: the pull request it opens is passed on only when its JSON
body's `head` is `pool/<id>` (or `<owner>:pool/<id>`) in that same repository; which repositories a slot reaches is the
sites' own list, not the filter's. Passed means passed the filter: GitHub may still refuse it.

A slot's `POST /graphql` comes here as well, GraphQL naming no repository in its path: it is passed on only when its
body is one `markPullRequestReadyForReview` mutation of one `pullRequestId`, nothing else (no other field, alias,
fragment, directive or operation), and that pull request, read upstream with a query of the filter's own, is
`pool/<id>` of a repository in the slot's `repos`, from that repository. The fleet's sidecar sends msi's here as slot
`.fleet`, with no manifest: for it the head is any task's `pool/<id>`, and the filter's own read query is answered
too, for a listed repository's pull request alone. A refusal after that read tells the slot a fixed text, never
what the owner's token read, and each slot reads at most MAX_LOOKUPS pull requests in LOOKUP_WINDOW (`.fleet`,
FLEET_READS times that for each of the `slots` it stands for). A refusal by the filter upstream (acer's, for msi's
read) reaches the slot as that filter's own text; any other failed read is a "try again later".

GitHub's own answer is passed back as it comes, so the client sees whether the push landed. A broken upstream is a 502
and nothing is tried again: the push may or may not have landed, and only the client (the park checks with ls-remote)
decides what to do.

With TEXTFILE, each slot's receive-pack requests passed and refused (a large push is two: git's empty probe first) are
counted there for node-exporter, as exec_pool_push_filter_pushes_total{slot,result}, and its pull request creations as
exec_pool_push_filter_pulls_total{slot,result} (ready marks included); a request naming no known slot counts as slot
"unknown".

SLOTS is a JSON object: each slot's {"manifest": the runner's file or null, "repos": ["owner/repo", ...]}, and for
`.fleet` "slots": how many slots of the fleet's hosts share its read budget.

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
import time
from collections.abc import Iterator
from typing import Any, NamedTuple
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
GRAPHQL_PATH = "/graphql"
# one ready mark is a few hundred bytes
MAX_GRAPHQL_BODY = 1 << 14
# a GraphQL global id, PR_kwDO... or the older base64 form
NODE_ID = re.compile(r"[A-Za-z0-9_=+/-]{1,200}")
# the read the filter composes itself: a request's own query is never sent to find a head
RESOLVE = ("query($id: ID!) { node(id: $id) { ... on PullRequest { headRefName "
           "headRepository { nameWithOwner } repository { nameWithOwner } } } }")
# the GraphQL tokens a ready mark needs: a name, a plain string, `$ ! : ( ) { }`; anything else (`...`, `@`, `=`,
# `[`, a number, a block string, a comment, a BOM: where another parser could end it apart) is no ready mark
TOKEN = re.compile(r'[ \t\n\r,]+|(?P<name>[_A-Za-z][_0-9A-Za-z]*)'
                   r'|(?P<str>"(?:[^"\\\x00-\x1f]|\\(?:["\\/bfnrt]|u[0-9A-Fa-f]{4}))*")(?!")|(?P<punct>[$!:(){}])')
# what a ready mark may read back of its own result, nothing a query could use
PAYLOAD = {"__typename", "clientMutationId"}
PULL_FIELDS = {"__typename", "id", "number", "isDraft", "url"}
CHUNK = 65536
PASSED = ("Content-Type", "Accept", "Accept-Encoding", "Accept-Language", "Git-Protocol", "User-Agent", "Host",
          "X-GitHub-Api-Version")
RETURNED = ("Content-Type", "Content-Encoding", "Cache-Control", "Expires", "Pragma", "Location")
METRICS = {"push": ("exec_pool_push_filter_pushes_total",
                    "git-receive-pack requests from a pool slot the ref filter passed or refused."),
           "pull": ("exec_pool_push_filter_pulls_total",
                    "Pull request creations from a pool slot the filter passed or refused.")}
RESULTS = ("passed", "refused")
# the fleet's sidecar's slot: no instance name starts with a dot
FLEET = ".fleet"
MAX_RESOLVE = 1 << 16
# reads upstream with the owner's token, per slot: a few ready marks, never a scan of the owner's pull requests
MAX_LOOKUPS, LOOKUP_WINDOW = 20, 600.0
# each mark of a fleet slot is read twice here (its host's filter's read, then the mark's own)
FLEET_READS = 2
# what the filter's refusals say: an upstream answer with it is a filter's refusal, not GitHub's
REFUSED_PULL = "pull request refused by the pool's filter: "


class Slot(NamedTuple):
    manifest: str | None
    repos: frozenset[str]
    slots: int


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
    @property
    def public(self) -> str:
        return str(self)


class Hidden(Refused):
    """A refusal that names what the owner's token read upstream: the journal gets it, the slot a fixed text."""

    @property
    def public(self) -> str:
        return "not a pull request of this slot's task"


class Upstream(Refused):
    """A refusal by the filter upstream: the slot gets its text as that filter sent it, which names nothing read."""

    def __init__(self, text: str) -> None:
        super().__init__(f"refused upstream: {text}")
        self.text = text

    @property
    def public(self) -> str:
        return self.text


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


def task_id(manifest: str | None) -> str:
    if manifest is None:
        raise Refused("no task: this slot only marks a task's pull request ready")
    try:
        with open(manifest, encoding="utf-8") as f:
            task_id = json.load(f)["task"]["id"]
    except (OSError, ValueError, KeyError, TypeError) as e:
        raise Refused(f"no task in {manifest}: {e}") from e
    if not isinstance(task_id, str) or not TASK_ID.fullmatch(task_id):
        raise Refused(f"task id {task_id!r}")
    return task_id


def own_refs(manifest: str | None) -> set[str]:
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
    if "issue" in pr:
        raise Refused("an issue turned into a pull request: it may be anyone's")
    head, branch = pr.get("head"), f"pool/{task}"
    # `<owner>:<branch>` names a fork's branch: only the repository's own owner is the same repository
    who, colon, ref = head.rpartition(":") if isinstance(head, str) else ("", "", "")
    if ref != branch or colon and who.lower() != owner.lower():
        raise Refused(f"head {head!r}: a slot opens a pull request only from {branch}")
    head_repo = pr.get("head_repo")
    if head_repo is not None and (not isinstance(head_repo, str) or head_repo.lower() not in (
            repo.lower(), f"{owner}/{repo}".lower())):
        raise Refused(f"head_repo {head_repo!r}: a slot opens a pull request only from {owner}/{repo}")


def tokens(query: str) -> list[tuple[str, str]]:
    """The query's tokens as (kind, text), its ignored ones dropped; refused at the first it cannot read."""
    out, at = [], 0
    while at < len(query):
        m = TOKEN.match(query, at)
        if m is None:
            raise Refused(f"no GraphQL token a ready mark uses at {query[at:at + 20]!r}")
        if m.lastgroup is not None:
            out.append((m.lastgroup, m.group()))
        at = m.end()
    return out


def ready_mark(body: bytes) -> str:
    """The pull request id of a body that is one markPullRequestReadyForReview mutation and nothing else."""
    try:
        req = json.loads(body, object_pairs_hook=unique_keys)
    except (ValueError, RecursionError) as e:
        raise Refused(f"not a JSON body: {e}") from e
    # a list is a batch of operations
    if not isinstance(req, dict) or not isinstance(req.get("query"), str) or set(req) - {"query", "variables",
                                                                                       "operationName"}:
        raise Refused("not one GraphQL request of query, variables and operationName")
    toks = tokens(req["query"])
    toks.append(("end", ""))
    at = 0

    def take(kind: str, text: str | None = None) -> str:
        nonlocal at
        k, t = toks[at]
        if k != kind or text is not None and t != text:
            raise Refused(f"{t or 'the end'!r} where a ready mark has {text or kind}")
        at += 1
        return t

    def peek(text: str) -> bool:
        return toks[at][1] == text and toks[at][0] != "str"

    take("name", "mutation")
    name = take("name") if toks[at][0] == "name" else None
    var = vtype = None
    if peek("("):
        take("punct", "(")
        take("punct", "$")
        var = take("name")
        take("punct", ":")
        vtype = take("name")
        if vtype not in ("ID", "MarkPullRequestReadyForReviewInput"):
            raise Refused(f"a variable of type {vtype}")
        if peek("!"):
            take("punct", "!")
        take("punct", ")")
    take("punct", "{")
    take("name", "markPullRequestReadyForReview")
    take("punct", "(")
    take("name", "input")
    take("punct", ":")
    used = pr = utype = None
    if peek("$"):
        take("punct", "$")
        used, utype = take("name"), "MarkPullRequestReadyForReviewInput"
    else:
        take("punct", "{")
        take("name", "pullRequestId")
        take("punct", ":")
        if peek("$"):
            take("punct", "$")
            used, utype = take("name"), "ID"
        else:
            # the token holds no control character: this is JSON's own string
            pr = json.loads(take("str"))
        take("punct", "}")
    take("punct", ")")
    # its result: a few fields of the payload and the pull request, never an alias, argument or fragment
    take("punct", "{")
    while not peek("}"):
        field = take("name")
        if field == "pullRequest" and peek("{"):
            take("punct", "{")
            while not peek("}"):
                if take("name") not in PULL_FIELDS or peek(":") or peek("("):
                    raise Refused(f"a ready mark reads back only {', '.join(sorted(PULL_FIELDS))} of its pull request")
            take("punct", "}")
        elif field not in PAYLOAD or peek(":") or peek("("):
            raise Refused(f"a ready mark reads back only its pullRequest, {', '.join(sorted(PAYLOAD))}")
    take("punct", "}")
    take("punct", "}")
    take("end")
    if req.get("operationName") not in (None, name):
        raise Refused(f"operationName {req.get('operationName')!r} names no operation of the body")
    variables = req.get("variables")
    if used != var or used is not None and utype != vtype:
        raise Refused("a variable declared and used apart")
    if var is None:
        if variables not in (None, {}):
            raise Refused("variables no operation declares")
    else:
        if not isinstance(variables, dict) or set(variables) != {var}:
            raise Refused(f"variables other than ${var}")
        pr = variables[var]
        if vtype != "ID":
            if not isinstance(pr, dict) or set(pr) != {"pullRequestId"}:
                raise Refused("an input other than one pullRequestId")
            pr = pr["pullRequestId"]
    if not isinstance(pr, str) or not NODE_ID.fullmatch(pr):
        raise Refused(f"pull request id {pr!r}")
    return pr


def filter_refusal(raw: bytes) -> str | None:
    """The reason in a pool filter's own refusal of a pull request call, else None (GitHub's 403, a proxy's)."""
    try:
        msg = json.loads(raw)
    except (ValueError, RecursionError):
        return None
    text = msg.get("message") if isinstance(msg, dict) and set(msg) == {"message"} else None
    if not isinstance(text, str) or not text.startswith(REFUSED_PULL):
        return None
    why = text[len(REFUSED_PULL):]
    # a filter's reasons are one short line
    return why if 0 < len(why) <= 300 and why.isprintable() else None


def resolve_body(node: str) -> bytes:
    return json.dumps({"query": RESOLVE, "variables": {"id": node}}).encode()


def resolve_request(body: bytes) -> str | None:
    """The id a body asks for when it is the filter's own read query, else None."""
    try:
        req = json.loads(body, object_pairs_hook=unique_keys)
    except (ValueError, RecursionError, Refused):
        return None
    if not isinstance(req, dict) or set(req) != {"query", "variables"} or req["query"] != RESOLVE:
        return None
    v = req["variables"]
    node = v.get("id") if isinstance(v, dict) and set(v) == {"id"} else None
    return node if isinstance(node, str) and NODE_ID.fullmatch(node) else None


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
    slots: dict[str, Slot] = {}
    lookups: dict[str, list[float]] = {}
    lookups_lock = threading.Lock()
    counts = Counts(None, [])

    def address_string(self) -> str:
        return "caddy"

    def log_message(self, format: str, *args: object) -> None:
        pass

    def note(self, what: str) -> None:
        print(f"{what} slot={self.headers.get('X-Pool-Slot')!r} path={self.path!r}", file=sys.stderr, flush=True)

    def kind(self) -> str:
        path = self.path.split("?", 1)[0]
        return "pull" if PULLS_PATH.fullmatch(path) or path.lower() == GRAPHQL_PATH else "push"

    def refuse(self, why: str, public: str | None = None) -> None:
        self.note(f"refused ({why})")
        why = why if public is None else public
        kind = self.kind()
        self.counts.bump(kind, self.headers.get("X-Pool-Slot", ""), "refused")
        if kind == "pull":
            # gh prints an API error's message
            msg = json.dumps({"message": REFUSED_PULL + why}).encode()
            ctype = "application/json"
        else:
            msg = f"push refused by the pool's ref filter: {why}\n".encode()
            ctype = "text/plain"
        self.answer(403, ctype, msg)

    def answer(self, status: int, ctype: str, msg: bytes) -> None:
        self.close_connection = True
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(msg)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(msg)

    def do_POST(self) -> None:
        try:
            self.filter()
        except Refused as e:
            self.refuse(str(e), e.public)

    def do_GET(self) -> None:
        self.refuse("only a git-receive-pack, pull request or GraphQL POST is filtered")

    def filter(self) -> None:
        slot = self.headers.get("X-Pool-Slot", "")
        if slot not in self.slots:
            raise Refused("no such slot")
        if self.path == GRAPHQL_PATH:
            self.graphql(self.slots[slot], self.json_body(MAX_GRAPHQL_BODY))
            return
        pulls = PULLS_PATH.fullmatch(self.path)
        if pulls is None and not REPO_PATH.fullmatch(self.path):
            raise Refused("not a repository's git-receive-pack")
        if pulls is not None:
            data = self.json_body(MAX_PULL_BODY)
            task = task_id(self.slots[slot].manifest)
            check_pull(data, pulls.group(1), pulls.group(2), task)
            self.note(f"passed a pull request from pool/{task}")
            self.counts.bump("pull", slot, "passed")
            self.forward(data, None)
            return
        allowed = own_refs(self.slots[slot].manifest)
        body = self.body()
        refs, head = updates(body)
        wrong = [r for r in refs if r not in allowed]
        if wrong:
            raise Refused(f"{', '.join(wrong)}: a slot pushes only {' and '.join(sorted(allowed))}")
        self.note(f"passed {refs}")
        self.counts.bump("push", slot, "passed")
        self.forward(head, body)

    def json_body(self, limit: int) -> bytes:
        # what GitHub parses as a form could hold another head than the JSON this reads
        if self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower() != "application/json":
            raise Refused("not an application/json body")
        data = self.body().read(limit + 1)
        if len(data) > limit:
            raise Refused(f"a body over {limit} bytes")
        return data

    def graphql(self, slot: Slot, data: bytes) -> None:
        if slot.manifest is None and (asked := resolve_request(data)) is not None:
            raw, pr = self.lookup(asked)
            repo = pr["repository"]["nameWithOwner"]
            if repo.lower() not in slot.repos:
                raise Hidden(f"{repo}'s pull request: not a listed repository's")
            self.note(f"answered the filter's read of {repo}'s {pr['headRefName']}")
            self.answer(200, "application/json", raw)
            return
        node = ready_mark(data)
        _, pr = self.lookup(node)
        repo, head = pr["repository"]["nameWithOwner"], pr["headRefName"]
        from_repo = (pr.get("headRepository") or {}).get("nameWithOwner")
        if repo.lower() not in slot.repos:
            raise Hidden(f"{repo}'s pull request: not a listed repository's")
        if not isinstance(from_repo, str) or from_repo.lower() != repo.lower():
            raise Hidden(f"a pull request from {from_repo!r}, not from {repo}")
        if slot.manifest is None:
            if not (head.startswith("pool/") and TASK_ID.fullmatch(head[5:])):
                raise Hidden(f"head {head!r}: the fleet marks ready only a task's pool/<id>")
        elif head != f"pool/{task_id(slot.manifest)}":
            raise Hidden(f"head {head!r}: a slot marks ready only its own task's pull request")
        self.note(f"passed the ready mark of {repo}'s {head}")
        self.counts.bump("pull", self.headers.get("X-Pool-Slot", ""), "passed")
        self.forward(data, None)

    def lookup(self, node: str) -> tuple[bytes, dict[str, Any]]:
        """The pull request node is, read upstream with the filter's own query: the answer as sent, and its node."""
        slot, now = self.headers.get("X-Pool-Slot", ""), time.monotonic()
        with self.lookups_lock:
            recent = [t for t in self.lookups.get(slot, []) if now - t < LOOKUP_WINDOW]
            limit = MAX_LOOKUPS * self.slots[slot].slots * (FLEET_READS if slot == FLEET else 1)
            if len(recent) >= limit:
                raise Refused(f"over {limit} pull request reads in {LOOKUP_WINDOW:.0f} s: try again later")
            self.lookups[slot] = [*recent, now]
        conn = UnixConnection(self.upstream)
        try:
            conn.request("POST", GRAPHQL_PATH, body=resolve_body(node),
                         headers={"Content-Type": "application/json", "Accept": "application/json",
                                  "User-Agent": "exec-pool-push-filter"})
            resp = conn.getresponse()
            raw = resp.read(MAX_RESOLVE + 1)
        except (OSError, http.client.HTTPException) as e:
            raise Refused(f"the pull request could not be read upstream, try again later: {e}") from e
        finally:
            conn.close()
        if resp.status != 200 or len(raw) > MAX_RESOLVE or resp.getheader("Content-Encoding", "identity") != "identity":
            if resp.status == 403 and len(raw) <= MAX_RESOLVE and (text := filter_refusal(raw)) is not None:
                raise Upstream(text)
            # a status names nothing the token read: GitHub's failure, or through acer's sidecar acer's proxy (a 502)
            raise Refused(f"the pull request could not be read upstream ({resp.status}), try again later")
        try:
            pr = json.loads(raw)["data"]["node"]
            if not (isinstance(pr["headRefName"], str) and isinstance(pr["repository"]["nameWithOwner"], str)
                    and isinstance(pr.get("headRepository") or {}, dict)):
                raise TypeError("not a pull request's fields")
        except (ValueError, KeyError, TypeError) as e:
            raise Hidden(f"{node} is no pull request upstream: {e!r}") from e
        return raw, pr

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
        Handler.slots = {n: Slot(v["manifest"], frozenset(r.lower() for r in v["repos"]), v.get("slots", 1))
                         for n, v in json.load(f).items()}
    if any(type(s.slots) is not int or s.slots < 1 for s in Handler.slots.values()):
        print("SLOTS: a slot's \"slots\" is not a positive integer", file=sys.stderr)
        return 2
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
