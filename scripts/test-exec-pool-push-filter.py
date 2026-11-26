#!/usr/bin/env python3
"""pkgs/exec-pool-push-filter with real git pushes: git -> Caddy (a slot site's receive-pack route, X-Pool-Slot set)
-> the filter -> Caddy's push socket -> git http-backend on a bare repository. A slot pushes its task's
`pool/<id>` and `refs/pool-wip/<id>` (a large push too, chunked), and nothing else: another branch, another task's,
a tag, a mixed push, a push with no manifest, an unknown slot and an unreadable body leave the remote as it was.
A pull request it opens (`POST /repos/o/r/pulls`, the slot site's route to the filter too) reaches the API only from
`pool/<id>`; another branch, another task's, a fork's or a body it cannot read is refused, and other API calls pass.
Its GraphQL (`POST /graphql`, routed to the filter too) passes one markPullRequestReadyForReview of the task's own pull
request, its head read with the filter's own query; another task's, branch's, fork's or unlisted repository's, and any
body with more or other than that mutation, is refused. The fleet's slot `.fleet` marks any task's ready and answers
the filter's read for a listed repository alone.
Its textfile counts each passed and refused request by slot, the first refusal included.
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
    """git http-backend as CGI over ROOT, the upstream GitHub stands for, and its REST API under /repos/, which records
    each call it gets."""
    protocol_version = "HTTP/1.1"
    root = ""
    api = []
    # GraphQL's pull requests by node id: (head, the repository it is from, the repository it is on)
    nodes = {"PR_own": ("pool/t-1", "o/r", "o/r"), "PR_other_task": ("pool/t-2", "o/r", "o/r"),
             "PR_main": ("main", "o/r", "o/r"), "PR_fork": ("pool/t-1", "f/r", "o/r"),
             "PR_unlisted": ("pool/t-1", "x/pub", "x/pub"), "PR_gone_fork": ("pool/t-1", None, "o/r")}
    reads = []

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

    def json(self, out):
        out = json.dumps(out).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def do_POST(self):
        if self.path == "/graphql":
            req = json.loads(self.body())
            if req["query"].startswith("query($id: ID!) { node(id: $id)"):
                Backend.reads.append(req)
                n = Backend.nodes.get(req["variables"]["id"])
                self.json({"data": {"node": n and {"headRefName": n[0], "headRepository": n[1] and {"nameWithOwner": n[1]},
                                                   "repository": {"nameWithOwner": n[2]}}}})
            else:
                Backend.api.append((self.path, json.dumps(req).encode()))
                self.json({"data": {"markPullRequestReadyForReview": {"pullRequest": {"isDraft": False}}}})
            return
        if self.path.startswith("/repos/"):
            Backend.api.append((self.path, self.body()))
            out = b'{"number": 1}'
            self.send_response(201)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)
            return
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


def raw(sock, slot, body, headers=None, path="/o/r.git/git-receive-pack"):
    """A request straight to the filter's socket, the way Caddy would send it."""
    conn = http.client.HTTPConnection("localhost", timeout=10)
    conn.sock = socket.socket(socket.AF_UNIX)
    conn.sock.connect(sock)
    h = {"Content-Type": "application/x-git-receive-pack-request", **(headers or {})}
    if slot is not None:
        h["X-Pool-Slot"] = slot
    conn.request("POST", path, body=body, headers=h)
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
        (d / "slots.json").write_text(json.dumps({"pool1": {"manifest": str(manifest), "repos": ["O/R"]},
                                                  ".fleet": {"manifest": None, "repos": ["o/r"]}}))
        fsock, push = str(d / "filter.sock"), str(d / "push.sock")
        port = free_port()
        (d / "Caddyfile").write_text(f"""{{
  admin off
  auto_https off
}}
http://127.0.0.1:{port} {{
  @receive path_regexp (?i)git-receive-pack
  @pulls {{
    path_regexp (?i)^/repos/(?i:o/r)/pulls/?$
    method POST
  }}
  handle @receive {{
    reverse_proxy unix/{fsock} {{
      header_up X-Pool-Slot pool1
      flush_interval -1
    }}
  }}
  handle @pulls {{
    reverse_proxy unix/{fsock} {{
      header_up X-Pool-Slot pool1
    }}
  }}
  @graphql {{
    path /graphql
    method POST
  }}
  handle @graphql {{
    reverse_proxy unix/{fsock} {{
      header_up X-Pool-Slot pool1
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
        prom = d / "push-filter.prom"
        filt = subprocess.Popen([FILTER, fsock, push, str(d / "slots.json"), str(prom)],
                                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        try:
            wait_for(lambda: socket.create_connection(("127.0.0.1", port), 0.2).close(), "caddy", caddy)
            wait_for(lambda: socket.socket(socket.AF_UNIX).connect(push), "caddy's push socket", caddy)
            wait_for(lambda: socket.socket(socket.AF_UNIX).connect(fsock), "the filter", filt)
            run(d, f"http://127.0.0.1:{port}/o/r.git", bare, fsock, manifest, prom)
            pulls(port, fsock, manifest, prom)
            graphql(port, fsock, prom)
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
    listed = subprocess.run([FILTER, "--list"], capture_output=True, text=True).stdout.split()
    check(listed == [PUSHES, PULLS], f"--list names the textfile's metrics ({listed})")
    finish()


PUSHES, PULLS = "exec_pool_push_filter_pushes_total", "exec_pool_push_filter_pulls_total"


def counts(prom, metric=PUSHES):
    """The textfile's series of metric as {(slot, result): value}."""
    out = {}
    for line in prom.read_text().splitlines():
        if line.startswith(metric + "{"):
            labels, value = line.split("{", 1)[1].split("} ")
            kv = dict(p.split("=", 1) for p in labels.split(","))
            out[(kv["slot"].strip('"'), kv["result"].strip('"'))] = int(value)
    return out


def run(d, url, bare, fsock, manifest, prom):
    zero = {(s, r): 0 for s in ("pool1", ".fleet", "unknown") for r in ("passed", "refused")}
    check(counts(prom) == zero and counts(prom, PULLS) == zero and oct(prom.stat().st_mode & 0o777) == "0o644",
          f"at start the textfile holds every series at 0, readable by node-exporter ({counts(prom)})")
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
    bad = push("HEAD:refs/heads/main")
    c = counts(prom)
    check(bad.returncode != 0 and refs() == before and c[("pool1", "refused")] == 1 and c[("pool1", "passed")] == 3,
          f"one refused push to main counts 1 refused beside the 3 passed ({c})")
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
    c = counts(prom)
    check(c[("unknown", "refused")] == 2 and c[("pool1", "refused")] == 12 and "pool9" not in str(c),
          f"a request with no slot or an unknown one counts as unknown, not as its header's name ({c})")


def api(port, path, body, headers=None, chunked=False):
    """A REST call as gh api sends it through the slot's site: its status and the JSON it got back."""
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    data = body if isinstance(body, bytes) else json.dumps(body).encode()
    conn.request("POST", path, body=iter([data]) if chunked else data, encode_chunked=chunked,
                 headers={"Content-Type": "application/json; charset=utf-8", "X-GitHub-Api-Version": "2022-11-28",
                          **(headers or {})})
    resp = conn.getresponse()
    out = resp.read()
    conn.close()
    try:
        return resp.status, json.loads(out or b"{}")
    except ValueError:
        return resp.status, {"text": out.decode(errors="replace")}


def pulls(port, fsock, manifest, prom):
    pr = {"head": "pool/t-1", "base": "main", "title": "t", "body": "b"}
    pushes = counts(prom)
    status, got = api(port, "/repos/o/r/pulls", pr)
    check(status == 201 and Backend.api == [("/repos/o/r/pulls", json.dumps(pr).encode())],
          f"a pull request from the task's own branch reaches the API as sent ({status} {got} {Backend.api})")
    status, _ = api(port, "/repos/O/r/pulls/", {**pr, "head": "o:pool/t-1", "head_repo": "r"})
    check(status == 201 and len(Backend.api) == 2, f"and named with the repository's own owner ({status})")
    status, _ = api(port, "/repos/o/r/pulls", {**pr, "head_repo": "o/r"}, chunked=True)
    check(status == 201 and len(Backend.api) == 3 and json.loads(Backend.api[-1][1])["head_repo"] == "o/r",
          f"and sent chunked, its repository named in full ({status})")
    for what, body in [
        ("main", {**pr, "head": "main"}),
        ("another task's branch", {**pr, "head": "pool/t-2"}),
        ("a branch under the task's", {**pr, "head": "pool/t-1/x"}),
        ("a fork's branch of that name", {**pr, "head": "other:pool/t-1"}),
        ("another repository's branch", {**pr, "head_repo": "elsewhere"}),
        ("no head", {"base": "main", "title": "t"}),
        ("a head given twice", b'{"head": "pool/t-1", "head": "main", "base": "main"}'),
        ("a body that is no JSON object", b'["pool/t-1"]'),
        ("a body that is no JSON", b"head=pool/t-1"),
        ("a head given twice, one escaped", b'{"head": "pool/t-1", "h\\u0065ad": "main"}'),
        ("an issue turned into one", {**pr, "issue": 7}),
        ("a body over 1 MiB", {**pr, "body": "x" * (1 << 20)}),
        ("another repository's branch named in full", {**pr, "head_repo": "o/elsewhere"}),
        ("a form body", (b"head=pool/t-1", {"Content-Type": "application/x-www-form-urlencoded"})),
        ("a compressed body", (json.dumps(pr).encode(), {"Content-Encoding": "gzip"})),
    ]:
        body, headers = body if isinstance(body, tuple) else (body, {})
        status, got = api(port, "/repos/o/r/pulls", body, headers)
        check(status == 403 and len(Backend.api) == 3 and "refused by the pool's filter" in got.get("message", ""),
              f"a pull request from {what} is refused with a message, and never reaches the API ({status} {got})")
    manifest.rename(manifest.with_suffix(".gone"))
    status, _ = api(port, "/repos/o/r/pulls", pr)
    check(status == 403 and len(Backend.api) == 3, "with no manifest (no task in the slot) no pull request is opened")
    manifest.with_suffix(".gone").rename(manifest)
    js = {"Content-Type": "application/json"}
    check(raw(fsock, "pool9", json.dumps(pr).encode(), js, "/repos/o/r/pulls") == 403
          and raw(fsock, "pool1", json.dumps(pr).encode(), js, "/repos/o/r/pulls?x=1") == 403 and len(Backend.api) == 3,
          "a pull request from a slot the filter does not know, or with a query, is refused")
    status, _ = api(port, "/repos/o/r/issues/1/comments", {"body": "head: main"})
    check(status == 201 and Backend.api[-1][0] == "/repos/o/r/issues/1/comments",
          f"another API call passes unread ({status})")
    c = counts(prom, PULLS)
    check(c[("pool1", "passed")] == 3 and c[("pool1", "refused")] == 17 and c[("unknown", "refused")] == 1
          and counts(prom) == pushes,
          f"pull requests count apart from pushes, the comment in neither ({c})")


READY = "mutation($id: ID!) { markPullRequestReadyForReview(input: {pullRequestId: $id}) { pullRequest { isDraft } } }"


def graphql(port, fsock, prom):
    Backend.api.clear()
    before = counts(prom, PULLS)
    status, got = api(port, "/graphql", {"query": READY, "variables": {"id": "PR_own"}})
    check(status == 200 and len(Backend.api) == 1 and Backend.reads[-1] == {
        "query": "query($id: ID!) { node(id: $id) { ... on PullRequest { headRefName headRepository { nameWithOwner } "
                 "repository { nameWithOwner } } } }", "variables": {"id": "PR_own"}},
          f"the ready mark of the task's own pull request reaches GraphQL, its head read with the filter's query ({status} {got})")
    for what, body in [
        ("inline", {"query": 'mutation Ready { markPullRequestReadyForReview(input: {pullRequestId: "PR_own"}) '
                             "{ clientMutationId pullRequest { id url } } }", "operationName": "Ready"}),
        ("its whole input a variable, commas and a comment", {
            "query": "mutation($in: MarkPullRequestReadyForReviewInput!) {\n  # gh api graphql\n"
                     "  markPullRequestReadyForReview(input: $in) { __typename, }\n}",
            "variables": {"in": {"pullRequestId": "PR_own"}}}),
    ]:
        status, _ = api(port, "/graphql", body)
        check(status == 200 and json.loads(Backend.api[-1][1]) == body, f"and written {what} ({status})")
    sent = len(Backend.api)
    for what, body in [
        ("another task's pull request", {"query": READY, "variables": {"id": "PR_other_task"}}),
        ("main's pull request", {"query": READY, "variables": {"id": "PR_main"}}),
        ("a fork's pull request from a branch of the task's name", {"query": READY, "variables": {"id": "PR_fork"}}),
        ("a pull request whose fork is gone", {"query": READY, "variables": {"id": "PR_gone_fork"}}),
        ("an unlisted repository's pull request", {"query": READY, "variables": {"id": "PR_unlisted"}}),
        ("a node that is no pull request", {"query": READY, "variables": {"id": "MDQ6VXNlcjE="}}),
        ("a second operation", {"query": READY + " query { viewer { login } }", "variables": {"id": "PR_own"}}),
        ("a second field", {"query": READY.replace("} } }", "} } viewer { login } }"), "variables": {"id": "PR_own"}}),
        ("an alias", {"query": READY.replace("{ markPull", "{ m: markPull"), "variables": {"id": "PR_own"}}),
        ("an aliased read back", {"query": READY.replace("{ isDraft }", "{ d: isDraft }"), "variables": {"id": "PR_own"}}),
        ("a read back of more than the pull request's own fields",
         {"query": READY.replace("{ isDraft }", "{ repository { name } }"), "variables": {"id": "PR_own"}}),
        ("a fragment", {"query": READY.replace("{ isDraft }", "{ ...F }") + " fragment F on PullRequest { isDraft }",
                        "variables": {"id": "PR_own"}}),
        ("a directive", {"query": READY.replace("isDraft", "isDraft @include(if: true)"), "variables": {"id": "PR_own"}}),
        ("a query", {"query": "query($id: ID!) { node(id: $id) { id } }", "variables": {"id": "PR_own"}}),
        ("the shorthand query", {"query": "{ viewer { login } }"}),
        ("a mutation by another name", {"query": READY.replace("markPullRequestReadyForReview", "mergePullRequest"),
                                        "variables": {"id": "PR_own"}}),
        ("the draft mark", {"query": READY.replace("markPullRequestReadyForReview", "convertPullRequestToDraft"),
                            "variables": {"id": "PR_own"}}),
        ("a second input field", {"query": READY.replace("$id}", "$id, clientMutationId: \"x\"}"),
                                  "variables": {"id": "PR_own"}}),
        ("a second input field in its variables", {
            "query": "mutation($in: MarkPullRequestReadyForReviewInput!) { markPullRequestReadyForReview(input: $in) "
                     "{ __typename } }", "variables": {"in": {"pullRequestId": "PR_own", "clientMutationId": "x"}}}),
        ("a second variable", {"query": READY, "variables": {"id": "PR_own", "other": "PR_main"}}),
        ("a variable declared and never used", {"query": READY.replace("$id}", '"PR_own"}'), "variables": {"id": "PR_main"}}),
        ("another operation named", {"query": READY, "variables": {"id": "PR_own"}, "operationName": "Other"}),
        ("a batch", [{"query": READY, "variables": {"id": "PR_own"}}]),
        ("a key given twice", b'{"query": "%s", "query": "{ viewer { login } }", "variables": {"id": "PR_own"}}'
         % READY.encode()),
        ("a key no GraphQL request has", {"query": READY, "variables": {"id": "PR_own"}, "extensions": {}}),
        ("a block string", {"query": READY.replace("$id}", '"""PR_own"""}').replace("($id: ID!) ", "")}),
        ("no JSON", b"mutation { markPullRequestReadyForReview }"),
        ("a form body", ({"query": READY}, {"Content-Type": "application/x-www-form-urlencoded"})),
        ("a control character in its id", {"query": READY.replace("$id}", '"PR_own\tx"}').replace("($id: ID!) ", "")}),
        ("a vertical tab, no GraphQL whitespace", {"query": READY.replace("mutation", "mutation\v"), "variables": {"id": "PR_own"}}),
        ("the filter's own read", {"query": RESOLVE, "variables": {"id": "PR_own"}}),
    ]:
        body, headers = body if isinstance(body, tuple) else (body, {})
        status, got = api(port, "/graphql", body, headers)
        check(status == 403 and len(Backend.api) == sent and "refused by the pool's filter" in got.get("message", "")
              and not any(w in got["message"] for w in ("x/pub", "f/r", "pool/t-2", "main'")),
              f"a GraphQL body with {what} is refused with a message naming nothing read upstream, and never reaches "
              f"GraphQL ({status} {got})")
    js = {"Content-Type": "application/json"}
    ready = json.dumps({"query": READY, "variables": {"id": "PR_own"}}).encode()
    check(raw(fsock, "pool1", ready, js, "/graphql?x=1") == 403 and raw(fsock, "pool1", ready, js, "/GRAPHQL") == 403
          and raw(fsock, "pool9", ready, js, "/graphql") == 403 and len(Backend.api) == sent,
          "a ready mark with a query, another spelling of the path, or from a slot the filter does not know, is refused")
    c = counts(prom, PULLS)
    check(c[("pool1", "passed")] - before[("pool1", "passed")] == 3
          and c[("pool1", "refused")] - before[("pool1", "refused")] == 33,
          f"ready marks count with the slot's pull requests ({c})")
    reads = len(Backend.reads)
    for _ in range(20):
        status, got = api(port, "/graphql", {"query": READY, "variables": {"id": "PR_main"}})
    check(status == 403 and "over 20 pull request reads" in got.get("message", "") and len(Backend.reads) - reads == 11,
          f"a slot reads at most 20 pull requests upstream in 10 minutes, then is refused before reading ({got})")
    fleet(fsock, ready, js, sent)


RESOLVE = ("query($id: ID!) { node(id: $id) { ... on PullRequest { headRefName "
                   "headRepository { nameWithOwner } repository { nameWithOwner } } } }")


def fleet(fsock, ready, js, sent):
    """The fleet's sidecar's slot: msi's filter's read and ready mark, already held to its task there."""
    def post(body):
        conn = http.client.HTTPConnection("localhost", timeout=10)
        conn.sock = socket.socket(socket.AF_UNIX)
        conn.sock.connect(fsock)
        conn.request("POST", "/graphql", body=json.dumps(body).encode(), headers={**js, "X-Pool-Slot": ".fleet"})
        resp = conn.getresponse()
        out = resp.read()
        conn.close()
        return resp.status, out

    status, out = post({"query": RESOLVE, "variables": {"id": "PR_other_task"}})
    check(status == 200 and json.loads(out)["data"]["node"]["headRefName"] == "pool/t-2" and len(Backend.api) == sent,
          f"the fleet's slot answers the filter's own read of a listed repository's pull request ({status} {out[:200]!r})")
    status, _ = post({"query": RESOLVE, "variables": {"id": "PR_unlisted"}})
    check(status == 403, f"and not of an unlisted repository's ({status})")
    status, _ = post({"query": RESOLVE.replace("headRefName", "headRefName title"), "variables": {"id": "PR_own"}})
    check(status == 403, f"nor any other read ({status})")
    status, _ = post({"query": READY, "variables": {"id": "PR_other_task"}})
    check(status == 200 and len(Backend.api) == sent + 1, f"it passes the ready mark of any task's pull request ({status})")
    for what, node in [("main's", "PR_main"), ("a fork's", "PR_fork"), ("an unlisted repository's", "PR_unlisted")]:
        status, _ = post({"query": READY, "variables": {"id": node}})
        check(status == 403 and len(Backend.api) == sent + 1, f"and refuses {what} ({status})")
    check(raw(fsock, ".fleet", b"x" * 10) == 403
          and raw(fsock, ".fleet", json.dumps({"head": "pool/t-1"}).encode(), js, "/repos/o/r/pulls") == 403,
          "the fleet's slot pushes nothing and opens no pull request")


if __name__ == "__main__":
    main()
