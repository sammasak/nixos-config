#!/usr/bin/env python3
"""The Platform health records (scripts/platform-record.sh, nixos-config#467): the dashboard queries only kinds the
helper writes and shows every one, each caller writes a known kind, and the helper itself labels a push with job,
kind and host alone, keeps a spool line, and never fails its caller when Loki is away or the kind is unknown."""
import http.server
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import threading

ROOT = pathlib.Path(__file__).resolve().parent.parent
HELPER = ROOT / "scripts/platform-record.sh"
DASHBOARD = ROOT / "modules/homelab/monitoring/dashboards/platform-health.json"
CALLERS = ["devenv.nix", "Justfile", "scripts/system-checks.sh", "modules/programs/cli/coordinator-wakeup.nix"]
failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


case = re.search(r"case \$kind in\n\s*([a-z| -]+)\)", HELPER.read_text())
kinds = set(case.group(1).replace(" ", "").split("|")) if case else set()
check(len(kinds) == 7, f"the helper's kind vocabulary is read ({sorted(kinds)})")

pi = re.search(r'black-pi\.address = "([0-9.]+)"', (ROOT / "modules/core/fleet.nix").read_text())
check(pi is not None and f"http://{pi.group(1)}:3100" in HELPER.read_text(),
      f"the helper's default Loki is black-pi's fleet address ({pi and pi.group(1)})")

exprs = [t["expr"] for p in json.loads(DASHBOARD.read_text())["panels"] for t in p.get("targets", [])]
used = {k for e in exprs for k in re.findall(r'kind="([^"]+)"', e)}
check(used <= kinds, f"the dashboard queries only kinds the helper writes (unknown: {sorted(used - kinds)})")
check(kinds <= used, f"every kind the helper writes has a panel (none: {sorted(kinds - used)})")
check(all('job="platform"' in e for e in exprs if "kind=" in e), "every Loki panel selects the platform stream")

written = {}
for c in CALLERS:
    for k in re.findall(r"(?:platform-record\.sh|getExe (?:record|platformRecord)\})\"? ([a-z-]+)", (ROOT / c).read_text()):
        written.setdefault(k, set()).add(c)
check(set(written) <= kinds, f"every caller writes a known kind (unknown: {sorted(set(written) - kinds)})")
check(set(written) == kinds, f"every kind has a writer ({ {k: sorted(v) for k, v in written.items()} })")


class Loki(http.server.BaseHTTPRequestHandler):
    bodies = []

    def do_POST(self):
        Loki.bodies.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


def run(kind, *fields, url):
    with tempfile.TemporaryDirectory() as tmp:
        spool = pathlib.Path(tmp) / "spool"
        env = dict(os.environ, PLATFORM_LOKI_URL=url, PLATFORM_RECORD_SPOOL=str(spool))
        out = subprocess.run(["bash", str(HELPER), kind, *fields], env=env, capture_output=True, text=True)
        return out.returncode, out.stderr, spool.read_text() if spool.exists() else ""


server = http.server.HTTPServer(("127.0.0.1", 0), Loki)
threading.Thread(target=server.serve_forever, daemon=True).start()
url = f"http://127.0.0.1:{server.server_port}"

rc, err, spool = run("deploy", "node=acer-swift", "result=ok", "seconds=12", url=url)
stream = Loki.bodies[0]["streams"][0] if Loki.bodies else {}
check(rc == 0 and len(Loki.bodies) == 1, f"a record is pushed once and exits 0 (rc {rc}, {len(Loki.bodies)} pushes, {err})")
check(set(stream.get("stream", {})) == {"job", "kind", "host"} and stream["stream"]["job"] == "platform"
      and stream["stream"]["kind"] == "deploy", f"its labels are job=platform, kind and host alone ({stream.get('stream')})")
check(stream.get("values", [[None, None]])[0][1] == "node=acer-swift result=ok seconds=12",
      f"the line is the fields as given ({stream.get('values')})")
check(re.fullmatch(r"\S+ deploy node=acer-swift result=ok seconds=12\n", spool) is not None, f"the spool keeps the line ({spool!r})")

server.shutdown()
rc, err, spool = run("gate", "result=fail", url=url)
check(rc == 0 and "did not take" in err and "gate result=fail" in spool,
      f"with Loki away the caller still exits 0 and the spool holds the record (rc {rc}, {err.strip()})")

rc, err, spool = run("deploys", "result=ok", url=url)
check(rc == 0 and "unknown kind" in err and spool == "", f"an unknown kind records nothing and exits 0 (rc {rc}, {err.strip()})")

sys.exit(1 if failed else 0)
