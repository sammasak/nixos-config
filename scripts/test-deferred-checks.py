"""scripts/deferred-checks.py on seeded records, without Nix: from a spool file and from a stand-in Loki. A deferral the
owner built on that head is ok; one whose drv the owner built on another head is ok; one with no owner record, a record
from another host, a failed owner run or another drv waits and exits 1; nothing deferred exits 0; unreadable records
exit 2."""
import http.server
import json
import pathlib
import subprocess
import sys
import tempfile
import threading

from gate_probe import check, finish

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "deferred-checks.py"
H1, H2 = "1" * 40, "2" * 40


def rec(result, check_name, owner, head, drv):
    return (f"gate-step gate=nixos-qa step=nixos-flake-check check={check_name} owner={owner} seconds=0 result={result} "
            f"head={head} drv={drv}")


A = "checks.x86_64-linux.deploy-schema-asus-b460m"
B = "ollama-gpu-test/asus-ollama-gpu-check"
C = "checks.x86_64-linux.deploy-activate-msi-ms7758"


def run(lines, *args):
    with tempfile.TemporaryDirectory() as t:
        spool = pathlib.Path(t) / "platform-records"
        spool.write_text("".join(f"2026-11-18T10:00:00+00:00 {k} {v}\n" for k, v in lines))
        r = subprocess.run([sys.executable, str(SCRIPT), *args, "--spool", str(spool)], capture_output=True, text=True)
        return r.returncode, r.stdout + r.stderr


base = [("gate-step", rec("deferred", A, "asus-b460m", H2, "/nix/store/a.drv")),
        ("gate-step", rec("deferred", B, "asus-b460m", H2, "/nix/store/b.drv")),
        ("gate", f"gate=nixos-qa result=pass head={H2} deferred_checks=asus-b460m:{A},asus-b460m:{B}")]

rc, out = run(base + [("gate-step", rec("built", A, "asus-b460m", H2, "/nix/store/a.drv")),
                      ("gate-step", rec("present", B, "asus-b460m", H1, "/nix/store/b.drv"))], H2)
check(rc == 0 and f"ok       asus-b460m:{A} (on this head)" in out and f"ok       asus-b460m:{B} (same drv on 111111111111)" in out,
      f"built on this head, or present for the same drv on another head: both covered, exit 0 ({rc}: {out.strip()})")

rc, out = run(base + [("gate-step", rec("built", A, "asus-b460m", H2, "/nix/store/a.drv"))], H2)
check(rc == 1 and f"waiting  asus-b460m:{B}" in out, f"seeded: no owner record for one check: it waits, exit 1 ({rc}: {out.strip()})")

rc, out = run(base + [("gate-step", rec("built", A, "msi-ms7758", H2, "/nix/store/a.drv")),
                      ("gate-step", rec("built", B, "asus-b460m", H2, "/nix/store/b.drv"))], H2)
check(rc == 1 and f"waiting  asus-b460m:{A}" in out, f"seeded: a record from another host does not count ({rc}: {out.strip()})")

rc, out = run(base + [("gate-step", rec("fail", A, "asus-b460m", H2, "/nix/store/a.drv")),
                      ("gate-step", rec("built", B, "asus-b460m", H1, "/nix/store/other.drv"))], H2)
check(rc == 1 and f"waiting  asus-b460m:{A}" in out and f"waiting  asus-b460m:{B}" in out,
      f"seeded: a failed owner run, and the owner's build of another drv on another head, do not count ({rc}: {out.strip()})")

rc, out = run([("gate-step", rec("deferred", A, "asus-b460m", H1, "/nix/store/a.drv"))], H2)
check(rc == 0 and "nothing was deferred" in out, f"a head with no deferral exits 0 ({rc}: {out.strip()})")

rc, out = run(base, "abc123")
check(rc != 0 and "full 40-character sha" in out, f"a short sha is refused: records carry the full one ({rc})")


class Loki(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 (the stdlib's name)
        values = [[str(i), rec(*r)] for i, r in enumerate([("deferred", A, "asus-b460m", H2, "/nix/store/a.drv"),
                                                          ("built", A, "asus-b460m", H2, "/nix/store/a.drv")])]
        body = json.dumps({"data": {"result": [{"stream": {"job": "platform", "kind": "gate-step", "host": "x"},
                                                "values": values}]}}).encode()
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Loki)
threading.Thread(target=server.serve_forever, daemon=True).start()
r = subprocess.run([sys.executable, str(SCRIPT), H2, "--loki", f"http://127.0.0.1:{server.server_port}"],
                   capture_output=True, text=True)
check(r.returncode == 0 and f"ok       asus-b460m:{A} (on this head)" in r.stdout,
      f"read from a Loki query_range answer, the same verdict ({r.returncode}: {(r.stdout + r.stderr).strip()})")
server.shutdown()
r = subprocess.run([sys.executable, str(SCRIPT), H2, "--loki", "http://127.0.0.1:1"], capture_output=True, text=True)
check(r.returncode == 2 and "cannot read the records" in r.stderr, f"an unreachable Loki exits 2, not 0 ({r.returncode})")

finish()
