"""scripts/deferred-checks.py on seeded records, without Nix, from a spool file and from a stand-in Loki that applies the
LogQL line filters it is sent. Covered (exit 0): the owner built, found present, or expected-failed the check's drv, on
HEAD or an earlier head. Waiting (exit 1): no owner record, a record from another host, a failed owner run, and an owner
run on HEAD of another drv (a dirty checkout). Cannot say (exit 2): no gate record for HEAD, fewer deferral records than
the gate counted, a query that hit its limit, an unreachable Loki, a short sha."""
import http.server
import json
import pathlib
import re
import subprocess
import sys
import tempfile
import threading
import urllib.parse

from gate_probe import check, finish

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "deferred-checks.py"
H1, H2 = "1" * 40, "2" * 40
A = "checks.x86_64-linux.deploy-schema-asus-b460m"
B = "ollama-gpu-test/asus-ollama-gpu-check-no-nvidia-libs"


def step(result, check_name, owner, head, drv):
    return ("gate-step", f"gate=nixos-qa step=nixos-flake-check check={check_name} owner={owner} seconds=0 "
                         f"result={result} head={head} drv={drv}")


def gate(head, checks, result="pass", checkout="clean"):
    listed = ",".join(f"asus-b460m:{c}" for c in checks)
    return ("gate", f"gate=nixos-qa seconds=1 result={result} sha={head[:7]} mode=push deferred={len(checks)} head={head} "
                    f"checkout={checkout} deferred_checks={listed}")


BASE = [gate(H2, [A, B]), step("deferred", A, "asus-b460m", H2, "/nix/store/a.drv"),
        step("deferred", B, "asus-b460m", H2, "/nix/store/b.drv")]


def run(lines, head=H2, *args):
    with tempfile.TemporaryDirectory() as t:
        spool = pathlib.Path(t) / "platform-records"
        spool.write_text("".join(f"2026-11-18T10:00:00+00:00 {k} {v}\n" for k, v in lines))
        r = subprocess.run([sys.executable, str(SCRIPT), head, *args, "--spool", str(spool)], capture_output=True, text=True)
        return r.returncode, r.stdout + r.stderr


rc, out = run(BASE + [step("built", A, "asus-b460m", H2, "/nix/store/a.drv"),
                      step("expected-fail", B, "asus-b460m", H1, "/nix/store/b.drv")])
check(rc == 0 and f"ok       asus-b460m:{A} (built on this head)" in out
      and f"ok       asus-b460m:{B} (expected-fail same drv on 111111111111)" in out,
      f"built on this head, or expected-fail for the same drv on an earlier head: covered, exit 0 ({rc}: {out.strip()})")
rc, out = run(BASE + [step("built", A, "asus-b460m", H2, "/nix/store/a.drv")])
check(rc == 1 and f"waiting  asus-b460m:{B}" in out, f"seeded: no owner record for one check: it waits, exit 1 ({rc}: {out.strip()})")
rc, out = run(BASE + [step("fetched", A, "asus-b460m", H2, "/nix/store/a.drv"), step("expected-fail", B, "asus-b460m", H2, "/nix/store/b.drv")])
check(rc == 0 and f"ok       asus-b460m:{A} (fetched on this head)" in out,
      f"the owner fetched the check's drv (a valid output exists there): covered ({rc}: {out.strip()})")
rc, out = run(BASE + [step("dry", A, "asus-b460m", H2, "/nix/store/a.drv"), step("fail", B, "asus-b460m", H2, "/nix/store/b.drv")])
check(rc == 1 and f"waiting  asus-b460m:{A}" in out and f"waiting  asus-b460m:{B}" in out,
      f"seeded: an owner record of dry (not built) or fail does not cover ({rc}: {out.strip()})")
r = subprocess.run([sys.executable, str(SCRIPT), H2, "--spool", "/nonexistent/platform-records"], capture_output=True, text=True)
check(r.returncode == 2 and "cannot say" in r.stderr, f"seeded: a missing spool file cannot say, exit 2, not waiting ({r.returncode}: {r.stderr.strip()})")
with tempfile.TemporaryDirectory() as t:
    lone = pathlib.Path(t) / "scripts" / "deferred-checks.py"
    lone.parent.mkdir()
    lone.write_text(SCRIPT.read_text())
    env = {k: v for k, v in __import__("os").environ.items() if k != "PLATFORM_LOKI_URL"}
    r = subprocess.run([sys.executable, str(lone), H2], capture_output=True, text=True, env=env)
    check(r.returncode == 2 and "cannot say" in r.stderr and "platform_record.py" in r.stderr,
          f"seeded: with no platform_record.py to read Loki's address from, cannot say, exit 2 ({r.returncode}: {r.stderr.strip()[-160:]})")
rc, out = run(BASE + [step("built", A, "msi-ms7758", H2, "/nix/store/a.drv"), step("built", B, "asus-b460m", H2, "/nix/store/b.drv")])
check(rc == 1 and f"waiting  asus-b460m:{A}" in out, f"seeded: a record from another host does not count ({rc}: {out.strip()})")
rc, out = run(BASE + [step("fail", A, "asus-b460m", H2, "/nix/store/a.drv"), step("built", B, "asus-b460m", H2, "/nix/store/dirty.drv")])
check(rc == 1 and f"waiting  asus-b460m:{A}" in out and f"waiting  asus-b460m:{B}" in out,
      f"seeded: a failed owner run, and an owner run on this head of another drv (a dirty checkout), do not count ({rc}: {out.strip()})")
rc, out = run(BASE[1:] + [step("built", A, "asus-b460m", H2, "/nix/store/a.drv")])
check(rc == 2 and "no passing gate record on a clean checkout" in out, f"seeded: no gate record for the head: cannot say, exit 2 ({rc}: {out.strip()})")
rc, out = run([gate(H2, [A, B]), BASE[1], step("built", A, "asus-b460m", H2, "/nix/store/a.drv")])
check(rc == 2 and f"lists asus-b460m:{B} as deferred, without its deferral record" in out,
      f"seeded: a check the gate lists, without its deferral record: cannot say, exit 2 ({rc}: {out.strip()})")
rc, out = run([gate(H2, [A, B], result="fail")] + BASE[1:] + [step("built", A, "asus-b460m", H2, "/nix/store/a.drv"),
                                                               step("built", B, "asus-b460m", H2, "/nix/store/b.drv")])
check(rc == 2 and "no passing gate record" in out, f"seeded: only a failed gate on the head: cannot say, exit 2 ({rc}: {out.strip()})")
rc, out = run([gate(H2, [])])
check(rc == 0 and "deferred nothing" in out, f"a passing gate that deferred nothing: exit 0 ({rc}: {out.strip()})")
rc, out = run([gate(H2, [], checkout="dirty")])
check(rc == 2 and "dirty checkout" in out,
      f"seeded: only a manual gate on a dirty checkout, deferring nothing: cannot say, exit 2 ({rc}: {out.strip()})")
# the pre-push hook (qaPush in devenv.nix) records the full gate as owed on a clean checkout of the head
owed = re.search(r"\$\{lib\.getExe record\} gate gate=nixos-qa-push [^\n]*result=owed[^\n]*mode=fast[^\n]*checkout=clean\n",
                 (ROOT / "devenv.nix").read_text())
check(owed is not None, "qaPush writes a gate record with result=owed, mode=fast and checkout=clean")
rc, out = run([("gate", f"gate=nixos-qa-push seconds=3 result=owed sha={H2[:7]} mode=fast head={H2} checkout=clean")])
check(rc == 2 and "no passing gate record on a clean checkout" in out,
      f"seeded: only a push's owed record on the head: not a passing gate, cannot say, exit 2 ({rc}: {out.strip()})")
rc, out = run(BASE, "abc123")
check(rc == 2 and "full 40-character sha" in out, f"a short sha is refused, exit 2 ({rc})")

# (kind, line, host label): msi claims asus's check for B, which must not count; asus's own present record does
LOKI_LINES = [(k, v, "acer-swift") for k, v in BASE] + [
    (*step("built", A, "asus-b460m", H2, "/nix/store/a.drv"), "asus-b460m"),
    (*step("built", B, "asus-b460m", H2, "/nix/store/b.drv"), "msi-ms7758"),
    (*step("present", B, "asus-b460m", H1, "/nix/store/b.drv"), "asus-b460m")]
# which owner record for B the stand-in serves: asus's own (honest), only msi's claim (forged), or asus's without a
# host label (unlabeled)
MODE = "honest"
queries = []
# a guest's stream (host <host>-<guest>) with the only gate record: run in the guest, not counted
GUEST_GATE = [(LOKI_LINES[0][0], LOKI_LINES[0][1], "msi-ms7758-canary")]


class Loki(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 (the stdlib's name)
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        query = q["query"][0]
        queries.append(query)
        kind = re.search(r'kind="([^"]+)"', query)[1]
        needles = re.findall(r'\|= "([^"]+)"', query)
        regex = re.search(r'\|~ "([^"]+)"', query)
        lines = {"honest": LOKI_LINES, "forged": LOKI_LINES[:-1],
                 "unlabeled": LOKI_LINES[:-2] + [(*LOKI_LINES[-1][:2], None)],
                 "guest": GUEST_GATE + LOKI_LINES[1:]}[MODE]
        hits = [(v, h) for k, v, h in lines if k == kind and all(n in v for n in needles) and (not regex or re.search(regex[1], v))]
        hits = hits[: int(q["limit"][0])]
        streams = {}
        for i, (v, h) in enumerate(hits):
            streams.setdefault(h, []).append([str(i), v])
        # a stream without a host label (h None) is sent without the key
        body = json.dumps({"data": {"result": [{"stream": {"job": "platform", "kind": kind, **({"host": h} if h else {})},
                                                "values": vs} for h, vs in streams.items()]}}).encode()
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Loki)
threading.Thread(target=server.serve_forever, daemon=True).start()
url = f"http://127.0.0.1:{server.server_port}"
r = subprocess.run([sys.executable, str(SCRIPT), H2, "--loki", url], capture_output=True, text=True)
check(r.returncode == 0 and f"ok       asus-b460m:{B} (present same drv on 111111111111)" in r.stdout
      and all(f'|= "head={H2}"' in q for q in queries[:2]) and any('|~ "result=(built|present|fetched|expected-fail)' in q for q in queries),
      f"from Loki, filtered in LogQL by head and by owner, check and drv: the same verdict ({r.returncode}: {(r.stdout + r.stderr).strip()})")
MODE = "forged"
r = subprocess.run([sys.executable, str(SCRIPT), H2, "--loki", url], capture_output=True, text=True)
check(r.returncode == 1 and f"waiting  asus-b460m:{B}" in r.stdout,
      f"seeded: a built record claiming owner asus-b460m but sent by msi-ms7758 (the stream's host) does not count ({r.returncode}: {r.stdout.strip()})")
MODE = "unlabeled"
r = subprocess.run([sys.executable, str(SCRIPT), H2, "--loki", url], capture_output=True, text=True)
check(r.returncode == 1 and f"waiting  asus-b460m:{B}" in r.stdout,
      f"seeded: from Loki, an owner record whose stream has no host label does not count ({r.returncode}: {r.stdout.strip()})")
MODE = "guest"
r = subprocess.run([sys.executable, str(SCRIPT), H2, "--loki", url], capture_output=True, text=True)
check(r.returncode == 2 and "gate ran in msi-ms7758-canary: not counted" in r.stdout and "from a fleet host" in r.stderr,
      f"seeded: the only passing gate record comes from a guest's stream: reported, not counted, exit 2 ({r.returncode}: "
      f"{(r.stdout + r.stderr).strip()})")
MODE = "honest"
r = subprocess.run([sys.executable, str(SCRIPT), H2, "--loki", url, "--limit", "2"], capture_output=True, text=True)
check(r.returncode == 2 and "hit its limit" in r.stderr, f"seeded: a query that fills its limit cannot say, exit 2 ({r.returncode})")
server.shutdown()
r = subprocess.run([sys.executable, str(SCRIPT), H2, "--loki", "http://127.0.0.1:1"], capture_output=True, text=True)
check(r.returncode == 2 and "cannot say" in r.stderr, f"an unreachable Loki exits 2, not 0 ({r.returncode})")

finish()
