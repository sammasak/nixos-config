"""scripts/check-tuning.py on an inline fixture of gate-step records, without Nix: a pass, a fail, a record without
seconds, a malformed seconds, one without step, skipped and deferred checks, two gates and spool lines; the rows and
the skipped and not-run counts, and that neither the malformed nor a not-run record is read as 0 seconds (it would
lower the mean and add a run). Then from a stand-in Loki: one query per day of --since, and a day at the line limit
refused (exit 2) instead of short counts."""
import http.server
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import threading
import urllib.parse

from gate_probe import check, finish

SCRIPT = pathlib.Path(__file__).resolve().parent / "check-tuning.py"

FIXTURE = """\
gate=nixos-qa-push step=nixos-push-eval seconds=120 result=pass sha=aaaa
gate=nixos-qa-push step=nixos-push-eval seconds=240 result=fail sha=bbbb
gate=nixos-qa-push step=nixos-push-eval seconds=abc result=pass sha=cccc
2026-11-26T10:00:00Z gate-step gate=pool-merge-check step=pool-merge-eval check=lenovo seconds=30 result=pass sha=dddd
gate=pool-merge-check step=pool-merge-eval check=lenovo result=pass sha=ffff
gate=pool-merge-check step=pool-merge-eval check=lenovo seconds=0 result=skipped sha=1111
gate=nixos-qa step=nixos-flake-check check=cuda owner=asus-b460m seconds=0 result=deferred head=2222
gate=nixos-qa seconds=30 result=pass sha=3333
2026-11-26T10:00:00Z gate gate=nixos-qa-push seconds=3 result=owed sha=4444
not a record at all

"""
SUMMARY = "3 records read, 2 not run (skipped, deferred or dry), 4 skipped (no step, or no whole seconds)"


def run(args: list[str], text: str | None = None, env: dict[str, str] | None = None) -> tuple[int, list[str]]:
    with tempfile.NamedTemporaryFile("w", suffix=".log") as f:
        f.write(text or "")
        f.flush()
        argv = [sys.executable, str(SCRIPT), *(["--records", f.name] if text is not None else []), *args]
        r = subprocess.run(argv, capture_output=True, text=True, check=False, env=env)
    return r.returncode, r.stdout.splitlines()


def rows(out: list[str]) -> list[str]:
    return [line for line in out if line.startswith("| ") and not line.startswith("| gate ")]


code, out = run([], FIXTURE)
check(code == 0, f"exit 0 on the fixture ({code})")
check(rows(out) == ["| nixos-qa-push | nixos-push-eval | - | 2 | 3.0 | 4.0 | 1 |",
                    "| pool-merge-check | pool-merge-eval | lenovo | 1 | 0.5 | 0.5 | 0 |"],
      f"one row per gate, step and check, with runs, mean and worst minutes and fails; seconds=abc and a "
      f"seconds=0 skipped or deferred check are no 0-second run, a stepless record no row ({rows(out)})")
check(SUMMARY in out, f"the stepless, secondless, malformed and non-record lines are skipped and counted, the not-run "
                      f"records counted apart, a spool line of another kind neither ({out[-1:]})")

code, out = run([], "gate=x step=y seconds= result=pass\n\n")
check(code == 2 and "0 records read, 0 not run (skipped, deferred or dry), 1 skipped (no step, or no whole seconds)"
      in out, f"only unreadable records: exit 2, nothing folded in ({code}, {out[-1:]})")

code, _ = run(["--since", "1d"], FIXTURE)
check(code == 2, f"--since with --records is refused ({code})")

env = {k: v for k, v in os.environ.items() if k != "LOKI_ADDR"}
code, _ = run([], env=env)
check(code == 2, f"no --records, no --loki and no LOKI_ADDR: exit 2 ({code})")

queries: list[dict[str, list[str]]] = []
LINES = ["gate=nixos-qa step=nixos-flake-check seconds=600 result=pass sha=5555"]


class Loki(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        queries.append(q)
        lines = LINES * int(q["limit"][0]) if os.environ.get("FULL_DAY") else LINES
        body = json.dumps({"data": {"result": [{"stream": {"host": "acer-swift"},
                                                "values": [[q["end"][0], line] for line in lines]}]}}).encode()
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_: object) -> None:
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Loki)
threading.Thread(target=server.serve_forever, daemon=True).start()
url = f"http://127.0.0.1:{server.server_port}"

code, out = run(["--loki", url, "--since", "36h"])
spans = [(int(q["start"][0]), int(q["end"][0])) for q in queries]
check(code == 0 and len(queries) == 2 and spans[0][0] == spans[1][1]
      and rows(out) == ["| nixos-qa | nixos-flake-check | - | 2 | 10.0 | 10.0 | 0 |"],
      f"--since 36h: two day queries that meet without overlap, a row per record read ({code}, {spans}, {rows(out)})")

queries.clear()
os.environ["FULL_DAY"] = "1"
code, out = run(["--loki", url, "--since", "7d"])
check(code == 2 and len(queries) == 1 and not rows(out),
      f"a day at the line limit: exit 2 and no table, not short counts ({code}, {len(queries)} queries)")
server.shutdown()

finish()
