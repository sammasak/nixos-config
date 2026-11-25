"""acer's slots' Codex on the owner's own login, sam.workers.codexAuthFile (modules/workers/codex-auth.nix), with no
login and no network: the proxy's openai site, run in Caddy against local stubs, sends POST /v1/responses to
/backend-api/codex/responses with the access token and account id read per request, the client's own values of both
replaced and nothing added, passes a usage-limit 429 through once and unchanged, answers a WebSocket upgrade 426 and
anything else 403, signs an API-key login for api.openai.com instead, and answers 503 while nothing was derived; the
token helper derives the files from auth.json, read as its owner, without printing them, waits out a half-written one
and keeps the last ones through it; the refresh helper, Codex run as the owner on that same file, asks app-server for
one refresh when half the token's life is gone, marks the attempt before it and never retries a failed or timed-out
one until the login changes, and says so in its textfile; a runner offers codex only while the ready marker exists;
no slot's binds, units or environment name the login or the derived files."""
import base64
import http.server
import json
import os
import pathlib
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

import gate_probe
from gate_probe import check, finish

P = gate_probe.section("codex-egress")
login = P["login"]
TOKEN = "eyJhbGciOiJub25lIn0.c2VjcmV0LXRva2Vu.c2ln"  # never printed by a helper
ACCOUNT = "acct-0000-secret"


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Stub(http.server.BaseHTTPRequestHandler):
    seen = []
    status = 200
    body = b"data: ok\n\n"

    def log_message(self, *_):
        pass

    def handle_one(self):
        n = int(self.headers.get("Content-Length") or 0)
        Stub.seen.append({"method": self.command, "path": self.path, "headers": [(k.lower(), v) for k, v in self.headers.items()],
                          "body": self.rfile.read(n)})
        self.send_response(Stub.status)
        self.send_header("Content-Type", "text/event-stream" if Stub.status == 200 else "application/json")
        self.send_header("Content-Length", str(len(Stub.body)))
        self.end_headers()
        self.wfile.write(Stub.body)

    do_POST = do_GET = handle_one


def site_of(caddyfile, slot, service):
    text = pathlib.Path(caddyfile).read_text()
    for block in text.split("http:// {")[1:]:
        if f"bind unix//run/dev-env-egress/{slot}/{service}.sock" in block.split("\n", 2)[1]:
            return block.split("\n", 3)[3].rsplit("\n}", 1)[0]
    return ""


def request(port, method, path, headers=None, body=b""):
    import http.client
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    conn.request(method, path, body=body or None, headers=headers or {})
    r = conn.getresponse()
    out = r.status, r.read()
    conn.close()
    return out


def check_route():
    site = site_of(P["caddyfile"], "pool1", "openai")
    check("https://chatgpt.com" in site and login["tokens"] in site, f"pool1's openai site goes to chatgpt.com with the derived tokens ({site[:200]!r})")
    caddy = shutil.which("caddy")
    if caddy is None:
        check(False, "caddy on PATH")
        return
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Stub)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = free_port()
    with tempfile.TemporaryDirectory() as d:
        tokens = pathlib.Path(d, "tokens")
        stub = f"http://127.0.0.1:{server.server_port}"
        body = site.replace("https://chatgpt.com", stub).replace("https://api.openai.com", stub).replace(login["tokens"], str(tokens))
        conf = pathlib.Path(d, "Caddyfile")
        conf.write_text("{\n admin off\n auto_https off\n}\nhttp://127.0.0.1:%d {\n%s\n}\n" % (port, body))
        proc = subprocess.Popen([caddy, "run", "--adapter", "caddyfile", "--config", str(conf)], stdout=subprocess.DEVNULL,
                                stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 30
            while True:
                if proc.poll() is not None:
                    check(False, f"caddy runs the site: {proc.stderr.read()[-400:]}")
                    return
                try:
                    socket.create_connection(("127.0.0.1", port), 0.2).close()
                    break
                except OSError:
                    if time.monotonic() > deadline:
                        check(False, "caddy listens within 30 s")
                        return
                    time.sleep(0.1)
            sent = {"Authorization": "Bearer held-by-the-host", "chatgpt-account-id": "client-chosen", "Cookie": "c=1",
                    "Content-Type": "application/json", "Accept-Encoding": "identity", "originator": "codex_exec", "session-id": "s1", "version": "0.162.1"}
            status, _ = request(port, "POST", "/v1/responses", sent, b'{"model":"m"}')
            check(status == 503 and Stub.seen == [], f"with nothing derived the route answers 503 and sends nothing upstream ({status}, {len(Stub.seen)})")
            tokens.mkdir()
            (tokens / "openai-key").write_text("sk-secret")
            status, _ = request(port, "POST", "/v1/responses", sent, b"{}")
            got = Stub.seen[-1] if Stub.seen else {"headers": [], "path": None}
            check(status == 200 and got["path"] == "/v1/responses" and dict(got["headers"]).get("authorization") == "Bearer sk-secret",
                  f"an API-key login: /v1/responses goes to api.openai.com as it is, signed with the key ({status}, {got['path']})")
            status, _ = request(port, "GET", "/backend-api/codex/responses", {}, b"")
            check(status == 403, f"an API-key login: a path outside /v1 is 403 ({status})")
            (tokens / "openai-key").unlink()
            Stub.seen.clear()
            (tokens / "access-token").write_text(TOKEN)
            (tokens / "account-id").write_text(ACCOUNT)
            status, _ = request(port, "POST", "/v1/responses", sent, b'{"model":"m","input":[]}')
            got = Stub.seen[-1] if Stub.seen else {"headers": [], "path": None, "body": None}
            h = dict(got["headers"])
            names = sorted(k for k, _ in got["headers"])
            want = sorted({k.lower() for k in sent} - {"cookie"} | {"host", "content-length"})
            check(status == 200 and got["path"] == "/backend-api/codex/responses" and got["body"] == b'{"model":"m","input":[]}',
                  f"POST /v1/responses reaches /backend-api/codex/responses with its body ({status}, {got['path']})")
            check(h.get("authorization") == f"Bearer {TOKEN}" and h.get("chatgpt-account-id") == ACCOUNT
                  and [k for k, _ in got["headers"]].count("authorization") == 1 and [k for k, _ in got["headers"]].count("chatgpt-account-id") == 1,
                  "the access token and account id replace the client's Authorization and chatgpt-account-id, once each")
            check(names == want and "cookie" not in h, f"upstream gets the slot's own headers and nothing added: no X-Forwarded-*, Via, other Accept-Encoding or Cookie ({names} vs {want})")
            (tokens / "access-token").write_text(TOKEN + "x")
            request(port, "POST", "/v1/responses", sent, b"{}")
            check(dict(Stub.seen[-1]["headers"]).get("authorization") == f"Bearer {TOKEN}x", "the token is read per request: a refreshed one is sent without a restart")
            Stub.status, Stub.body = 429, b'{"error":{"type":"usage_limit_reached","message":"You have hit your usage limit."}}'
            n = len(Stub.seen)
            status, answer = request(port, "POST", "/v1/responses", sent, b"{}")
            Stub.status, Stub.body = 200, b"data: ok\n\n"
            check(status == 429 and answer == b'{"error":{"type":"usage_limit_reached","message":"You have hit your usage limit."}}' and len(Stub.seen) == n + 1,
                  f"a usage-limit 429 reaches the slot unchanged, asked upstream once ({status}, {len(Stub.seen) - n})")
            n = len(Stub.seen)
            wrong = []
            for method, path, headers, want_status in [
                ("GET", "/v1/responses", {"Upgrade": "websocket", "Connection": "Upgrade", "Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ=="}, 426),
                ("GET", "/v1/models", {}, 403), ("POST", "/v1/chat/completions", {}, 403), ("POST", "/v1/responses/compact", {}, 403),
                ("POST", "/v1/alpha/search", {}, 403), ("GET", "/v1/responses", {}, 403), ("POST", "/backend-api/codex/responses", {}, 403),
                ("POST", "/v1/../backend-api/codex/analytics-events/events", {}, 403),
            ]:
                status, _ = request(port, method, path, headers, b"{}" if method == "POST" else b"")
                if status != want_status:
                    wrong.append(f"{method} {path} -> {status}")
            check(wrong == [] and len(Stub.seen) == n, f"a WebSocket upgrade is 426, every other path 403, and none reaches upstream ({wrong})")
        finally:
            proc.terminate()
            proc.wait(5)
            server.shutdown()


def stubbed(script, d, paths):
    """The helper's text with its host paths moved under d and chown/systemctl recorded, run under bash."""
    text = pathlib.Path(script).read_text()
    for real, fake in paths.items():
        text = text.replace(real, str(fake))
    stubs = pathlib.Path(d, "stubs")
    stubs.mkdir(exist_ok=True)
    for name in ("chown", "systemctl"):
        f = stubs / name
        f.write_text(f'#!/bin/sh\necho "{name} $*" >> {d}/calls\n')
        f.chmod(0o755)
    text = re.sub(r'^export PATH="', f'export PATH="{stubs}:', text, count=1, flags=re.M)
    # install -o and setpriv need root; the owner is chown's, recorded above
    text = re.sub(r"install -d -m 0755 -o \S+ -g \S+", "install -d -m 0755", text)
    text = re.sub(r"/nix/store/\S+/setpriv --reuid=\S+ --regid=\S+ --init-groups ", "", text)
    text = text.replace("sleep 1\n", "sleep 0.3\n")
    out = pathlib.Path(d, "derive")
    out.write_text(text)
    return out


def calls(d):
    f = pathlib.Path(d, "calls")
    return f.read_text().splitlines() if f.exists() else []


def check_derive():
    script = pathlib.Path(P["derive"]).read_text()
    check(f"--reuid={login['owner']} " in script and f"cat -- {login['auth']}" in script,
          f"the token helper reads {login['auth']} as {login['owner']}, so a link there reaches nothing root alone may read")
    with tempfile.TemporaryDirectory() as d:
        home, run = pathlib.Path(d, "home"), pathlib.Path(d, "run")
        home.mkdir()
        auth = home / "auth.json"
        script = stubbed(P["derive"], d, {login["auth"]: auth, os.path.dirname(login["tokens"]): run})
        tokens = run / "tokens"

        def derive():
            return subprocess.run(["bash", str(script)], capture_output=True, text=True)

        def files():
            return sorted(f.name for f in tokens.iterdir()) if tokens.exists() else []

        out = derive()
        check(out.returncode == 0 and not (run / "ready").exists() and "codex login --device-auth" in out.stderr and calls(d) == [],
              f"no login: no ready marker, the sign-in on stderr, no runner restart ({out.returncode}, {out.stderr[-200:]!r}, {calls(d)})")
        chatgpt = json.dumps({"auth_mode": "chatgpt", "OPENAI_API_KEY": None, "tokens": {"id_token": "x", "access_token": TOKEN, "refresh_token": "r-secret", "account_id": ACCOUNT},
                              "last_refresh": "2026-11-25T10:00:00Z"})
        auth.write_text(chatgpt)
        out = derive()
        mode = oct((tokens / "access-token").stat().st_mode & 0o777) if (tokens / "access-token").exists() else None
        check(out.returncode == 0 and (tokens / "access-token").read_text() == TOKEN and (tokens / "account-id").read_text() == ACCOUNT
              and files() == ["access-token", "account-id"] and mode == "0o400" and (run / "ready").exists() and oct(tokens.stat().st_mode & 0o777) == "0o755",
              f"a ChatGPT login: access-token and account-id 0400, alone in the helper's own directory, and the ready marker ({out.stderr[-200:]!r}, {mode}, {files()})")
        check(TOKEN not in out.stdout + out.stderr and ACCOUNT not in out.stdout + out.stderr and "r-secret" not in out.stdout + out.stderr,
              "the token helper prints neither the token, the account id nor the refresh token")
        check(any(c.startswith(f"chown {login['owner']}") for c in calls(d)) and calls(d)[-1] == "systemctl try-restart exec-pool-runner-*.service",
              f"the files are the proxy's user's, and the runners restart once the login appears ({calls(d)})")
        n = len(calls(d))
        derive()
        check(not any("systemctl" in c for c in calls(d)[n:]), f"a refreshed login restarts no runner ({calls(d)[n:]})")
        auth.write_text('{"tokens": {"access_')
        slow = subprocess.Popen(["bash", str(script)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        time.sleep(0.5)
        auth.write_text(chatgpt.replace(TOKEN, TOKEN + "n"))
        slow.communicate(timeout=30)
        check(slow.returncode == 0 and (tokens / "access-token").read_text() == TOKEN + "n",
              "a half-written auth.json is read again until it parses")
        auth.write_text('{"tokens": {"access_')
        out = derive()
        check((tokens / "access-token").read_text() == TOKEN + "n" and (run / "ready").exists() and out.returncode == 0 and "the last credentials stay" in out.stderr,
              "one that stays half-written keeps the last tokens and the marker")
        auth.write_text(json.dumps({"auth_mode": "apikey", "OPENAI_API_KEY": "sk-secret", "tokens": None}))
        out = derive()
        check(files() == ["openai-key"] and (tokens / "openai-key").read_text() == "sk-secret" and (run / "ready").exists() and "sk-secret" not in out.stderr,
              f"an API-key login: openai-key alone, and the marker ({files()})")
        auth.unlink()
        n = len(calls(d))
        out = derive()
        check(files() == [] and not (run / "ready").exists() and calls(d)[n:][-1:] == ["systemctl try-restart exec-pool-runner-*.service"],
              f"a removed login drops every file and the marker, and the runners restart ({calls(d)[n:]}, {files()})")


FAKE_CODEX = r'''
import json, os, sys, time
mode = os.environ["FAKE_MODE"]
open(os.environ["FAKE_LOG"], "a").write(" ".join(sys.argv[1:]) + "\n")
for line in sys.stdin:
    m = json.loads(line)
    if m.get("id") == 1:
        print(json.dumps({"id": 1, "result": {}}), flush=True)
    if m.get("method") == "account/read":
        assert m["params"] == {"refreshToken": True}
        open(os.environ["FAKE_LOG"] + ".marked", "a").write(f"{os.path.exists(os.environ['FAKE_FAILED'])}\n")
        if mode == "hang":
            time.sleep(60)
        if mode == "ok":
            p = os.environ["FAKE_AUTH"]
            a = json.load(open(p))
            a["last_refresh"] = "2026-11-25T12:00:00Z"
            a["tokens"]["refresh_token"] = "r2-secret"
            json.dump(a, open(p, "w"))
        print(json.dumps({"id": 2, "result": {"account": None}}), flush=True)
'''


def jwt(iat, exp):
    seg = base64.urlsafe_b64encode(json.dumps({"iat": iat, "exp": exp}).encode()).decode().rstrip("=")
    return f"eyJhbGciOiJub25lIn0.{seg}.c2ln"


def check_refresh():
    r = P["refresh"]
    env = r["environment"]
    check(f"--reuid={login['owner']} " in env["CODEX_EGRESS_CODEX"] and f"HOME={login['ownerHome']} " in env["CODEX_EGRESS_CODEX"]
          and f"CODEX_HOME={os.path.dirname(login['auth'])} " in env["CODEX_EGRESS_CODEX"] and 'cli_auth_credentials_store="file"' in env["CODEX_EGRESS_CODEX"]
          and env["CODEX_EGRESS_AUTH"] == login["auth"] and os.path.dirname(login["auth"]) in r["ReadWritePaths"]
          and r["onSuccess"] == ["codex-egress-token.service"],
          f"Codex refreshes as {login['owner']} in that user's own CODEX_HOME and file store, and every run derives again ({env['CODEX_EGRESS_CODEX'][-200:]!r})")
    with tempfile.TemporaryDirectory() as d:
        d = pathlib.Path(d)
        auth, failed, textfile, log = d / "auth.json", d / "failed", d / "codex-egress.prom", d / "log"
        fake = d / "fake-codex.py"
        fake.write_text(FAKE_CODEX)

        def run(mode, timeout="5"):
            e = {"PATH": os.environ["PATH"], "CODEX_EGRESS_AUTH": str(auth), "CODEX_EGRESS_FAILED": str(failed),
                 "CODEX_EGRESS_TEXTFILE": str(textfile), "CODEX_EGRESS_CODEX": f"{sys.executable} {fake} -c x",
                 "CODEX_EGRESS_TIMEOUT": timeout, "FAKE_MODE": mode, "FAKE_LOG": str(log), "FAKE_AUTH": str(auth),
                 "FAKE_FAILED": str(failed)}
            return subprocess.run([P["refresh"]["ExecStart"]], capture_output=True, text=True, env=e, timeout=60)

        def metrics():
            return dict(line.rsplit(" ", 1) for line in textfile.read_text().splitlines() if not line.startswith("#")) if textfile.exists() else {}

        def asked():
            return len(log.read_text().splitlines()) if log.exists() else 0

        def write(access, last="2026-11-25T10:00:00Z", refresh="r-secret"):
            auth.write_text(json.dumps({"tokens": {"access_token": access, "refresh_token": refresh, "account_id": ACCOUNT}, "last_refresh": last}))

        out = run("ok")
        check(out.returncode == 0 and metrics().get("codex_egress_login_present") == "0" and asked() == 0,
              f"no login: present 0, app-server not started ({out.stderr[-200:]!r}, {metrics()})")
        now = int(time.time())
        write(jwt(now - 100, now + 10000))
        out = run("ok")
        check(out.returncode == 0 and asked() == 0 and metrics().get("codex_egress_refresh_failed") == "0"
              and metrics().get("codex_egress_access_token_expiry_timestamp_seconds") == str(now + 10000),
              f"a token with most of its life left is not refreshed, its expiry exported ({metrics()})")
        write(jwt(now - 10000, now + 100))
        out = run("ok")
        check(out.returncode == 0 and asked() == 1 and "app-server" in log.read_text() and metrics().get("codex_egress_refresh_failed") == "0"
              and json.loads(auth.read_text())["last_refresh"] == "2026-11-25T12:00:00Z",
              f"past half its life: one app-server account/read with refreshToken, recorded as a refresh ({out.stderr[-200:]!r}, {metrics()})")
        marked = pathlib.Path(str(log) + ".marked").read_text().split()
        check(marked == ["True"] and not failed.exists(), f"the failure marker is written before the attempt and removed once it succeeded ({marked})")
        leaked = [s for s in (TOKEN, ACCOUNT, "r-secret", "r2-secret") if s in out.stdout + out.stderr + textfile.read_text()]
        check(leaked == [] and not re.search(r"\{[^}]*(acct|account)", textfile.read_text()), f"the refresh prints no token or id and its metrics carry no id label ({leaked})")
        for mode, why in (("silent", "did not record a new refresh"), ("hang", "did not answer in time")):
            write(jwt(now - 10000, now + 100), refresh=f"r-{mode}")
            failed.unlink(missing_ok=True)
            n = asked()
            out = run(mode, timeout="2")
            first = asked() - n
            out2 = run("ok")
            check(out.returncode == 0 and why in out.stderr and first == 1 and asked() - n == 1 and metrics().get("codex_egress_refresh_failed") == "1"
                  and "not retried" in out2.stderr,
                  f"a refresh that {why}: failed 1, and the next run does not ask again ({out.stderr[-200:]!r}, {out2.stderr[-200:]!r}, {metrics()})")
        write(jwt(now - 10000, now + 100), refresh="r-new-login")
        n = asked()
        run("ok")
        check(asked() - n == 1 and metrics().get("codex_egress_refresh_failed") == "0", f"a new login clears the failure and is refreshed again ({metrics()})")
        real = d / "elsewhere.json"
        auth.rename(real)
        auth.symlink_to(real)
        n = asked()
        run("ok")
        check(asked() == n and metrics().get("codex_egress_login_present") == "0", "a symlinked auth.json is not followed by root")


def check_runner():
    script = pathlib.Path(P["runner"]["ExecStart"]).read_text()
    exe = re.search(r"^exec (\S+) run$", script, re.M)
    marker = re.search(r"\[\[ ! -e (\S+) \]\]", script)
    check(exe is not None and marker is not None and marker.group(1) == os.path.dirname(login["tokens"]) + "/ready",
          f"the runner's wrapper checks {os.path.dirname(login['tokens'])}/ready before it runs the runner")
    if exe is None or marker is None:
        return
    with tempfile.TemporaryDirectory() as d:
        ready = pathlib.Path(d, "ready")
        text = script.replace(f"exec {exe.group(1)} run", 'printf %s "$EXEC_POOL_SLOT"').replace(marker.group(1), str(ready))

        def offered():
            out = subprocess.run(["bash", "-c", text], capture_output=True, text=True, env={**os.environ, "EXEC_POOL_SLOT": P["runner"]["EXEC_POOL_SLOT"]})
            return json.loads(out.stdout).get("agents") if out.returncode == 0 else out.stderr

        without = offered()
        ready.touch()
        check(without == ["none", "claude", "pi"] and offered() == ["none", "claude", "pi", "codex"] and "codex" in P["agents"],
              f"a runner offers codex only while the ready marker exists, and Claude and Pi either way ({without}, {offered()})")


def check_slots():
    secret = [login["auth"], os.path.dirname(login["auth"]), os.path.dirname(login["tokens"]), "auth.json", "codex-egress"]
    leaks = {n: [s for s in secret if s in json.dumps(v)] for n, v in P["slots"].items()}
    leaks["exec-pool-exec@"] = [s for s in secret if s in json.dumps(P["exec"])]
    check(len(P["slots"]) == 3 and not any(leaks.values()), f"no slot's binds, container unit, guest environment or guest units, nor the exec helper, name the login or its tokens ({leaks})")
    cfg = P["slots"]["pool1"]["codexConfig"]
    check(cfg.startswith('openai_base_url = "http://127.0.0.1:4103/v1"\nweb_search = "disabled"\n') and "\n[analytics]\nenabled = false\n" in cfg
          and P["slots"]["pool1"]["variables"].get("CODEX_API_KEY") == "held-by-the-host",
          "the slot's Codex holds a placeholder key and the proxy's base URL, with web search and analytics off")
    check(not any("codex" in c for c in P["egress"]["LoadCredential"]) and P["egress"]["User"] == "lukas",
          f"the proxy loads no Codex credential: it reads the derived files per request ({P['egress']['LoadCredential']})")
    check(P["path"] == {"PathChanged": login["auth"]} and login["auth"] == "/home/lukas/.codex/auth.json" and P["failing"]["acer"] == []
          and any("serveFleet" in m for m in P["failing"]["serveWithout"])
          and any("signed from the host user's Codex login in sam.workers.codexAuthFile" in m for m in P["failing"]["noLogin"]),
          f"the path unit watches the owner's own login, acer evaluates, and serveFleet or a codex slot without a login fails ({P['failing']})")


def check_fleet():
    f = P["fleet"]
    l = f["listener"]
    acer = pathlib.Path(f["acer"]).read_text()
    site = next((b for b in acer.split("\nhttp://:")[1:] if b.startswith(f"{l['port']} {{")), "")
    msi = site_of(f["msi"], "pool1", "openai")
    check(f["failing"] == {"acer": [], "msi": []} and l["host"] == "acer-swift", f"turned on (serveFleet, codex on msi): acer and msi evaluate ({f['failing']})")
    check(f"@outside not remote_ip {f['msiAddress']}\n" in site and "https://chatgpt.com" in site and login["tokens"] in site,
          f"acer serves :{l['port']} to msi's address alone, with its own ChatGPT route ({site[:200]!r})")
    check(f"reverse_proxy {l['url']} {{" in msi and "header_up -Authorization" in msi and "chatgpt.com" not in msi and "/run/codex-egress" not in msi
          and not any("codex" in c for c in f["msiCreds"]),
          f"msi's slots forward Codex to acer's {l['url']} and msi holds no login or credential ({msi[:200]!r})")
    off = pathlib.Path(P["offCaddy"]).read_text()
    check(f":{l['port']} {{" not in acer.split("\nhttp://:", 1)[0] and "codex-fleet" not in pathlib.Path(P["caddyfile"]).read_text() and "4103" not in off,
          "as committed, acer serves no fleet Codex route (serveFleet off) and msi's slots have none (no codex agent)")


def check_alert():
    rules = pathlib.Path("modules/homelab/monitoring/rules/exec-pool.yaml").read_text()
    alert = rules.split("- alert: CodexLoginRefreshFailed", 1)[-1].split("- alert:", 1)[0] if "CodexLoginRefreshFailed" in rules else ""
    check("codex login --device-auth" in alert and login["auth"] in alert and login["owner"] in alert,
          "CodexLoginRefreshFailed's description says how to sign in again, as whom and into which file")


check_route()
check_derive()
check_refresh()
check_runner()
check_slots()
check_fleet()
check_alert()
finish()
