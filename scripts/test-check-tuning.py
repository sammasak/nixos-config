"""scripts/check-tuning.py on an inline fixture of gate-step records, without Nix: a pass, a fail, a record without
seconds, a malformed seconds, one without step, skipped, deferred and dry checks, failed runs recorded with seconds=0,
gates side by side, spool and logcli lines and a | in a value; the rows and the counts, and that neither the malformed,
a not-run nor an unmeasured failed record is read as 0 seconds (it would lower the mean). Then from a stand-in Loki:
day queries back to exactly --since, a day at the line limit and an HTTP error refused (exit 2) instead of short
counts, and a URL with a password refused without printing it."""
import http.server
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

from gate_probe import check, finish

SCRIPT = pathlib.Path(__file__).resolve().parent / "check-tuning.py"

FIXTURE = """\
gate=nixos-qa-push step=nixos-push-eval seconds=120 result=pass sha=aaaa
gate=nixos-qa-push step=nixos-push-eval seconds=240 result=fail sha=bbbb
gate=nixos-qa-push step=nixos-push-eval seconds=abc result=pass sha=cccc
2026-11-26T10:00:00+01:00 gate-step gate=pool-merge-check step=pool-merge-eval check=lenovo seconds=30 result=pass sha=dddd
gate=pool-merge-check step=pool-merge-eval check=lenovo result=pass sha=ffff
gate=pool-merge-check step=pool-merge-eval check=lenovo seconds=0 result=skipped sha=1111
gate=nixos-qa step=nixos-flake-check check=cuda owner=asus-b460m seconds=0 result=deferred head=2222
gate=nixos-qa seconds=30 result=pass sha=3333
gate=nixos-qa step=nixos-flake-check check=x seconds=600 result=pass head=6666
gate=nixos-qa step=nixos-flake-check check=x seconds=0 result=fail head=7777
gate=nixos-qa step=nixos-flake-check check=y seconds=0 result=fail head=7777
gate=nixos-qa step=nixos-flake-check check=z seconds=0 result=dry head=7777
gate=on-demand step=s check=a|b seconds=60 result=pass sha=8888
2026-11-26T10:00:00+01:00 gate gate=nixos-qa-push seconds=3 result=owed sha=4444
2026-11-26T10:00:00+01:00 {host="acer-swift", kind="gate-step"} gate=nixos-qa step=x seconds=60 result=pass
not a record at all

"""
SUMMARY = ("7 records read, 3 not run (skipped, deferred or dry), 4 skipped (no step, or no whole seconds), "
           "2 of other kinds")


def run(args: list[str], text: str | None = None, env: dict[str, str] | None = None) -> tuple[int, list[str]]:
    with tempfile.NamedTemporaryFile("w", suffix=".log") as f:
        f.write(text or "")
        f.flush()
        argv = [sys.executable, str(SCRIPT), *(["--records", f.name] if text is not None else []), *args]
        r = subprocess.run(argv, capture_output=True, text=True, check=False, env=env)
    return r.returncode, r.stdout.splitlines() + r.stderr.splitlines()


def rows(out: list[str]) -> list[str]:
    return [line for line in out if line.startswith("| ") and not line.startswith("| gate ")]


code, out = run([], FIXTURE)
check(code == 0, f"exit 0 on the fixture ({code})")
check(rows(out) == ["| nixos-qa | nixos-flake-check | x | 2 | 10.0 | 10.0 | 1 |",
                    "| nixos-qa | nixos-flake-check | y | 1 | - | - | 1 |",
                    "| nixos-qa-push | nixos-push-eval | - | 2 | 3.0 | 4.0 | 1 |",
                    "| on-demand | s | a\\|b | 1 | 1.0 | 1.0 | 0 |",
                    "| pool-merge-check | pool-merge-eval | lenovo | 1 | 0.5 | 0.5 | 0 |"],
      f"one row per gate, step and check, with runs, mean and worst minutes and fails; seconds=abc, a seconds=0 "
      f"skipped, deferred or dry check and an unmeasured fail add no 0-second time, a stepless record no row, a | "
      f"is escaped ({rows(out)})")
check(SUMMARY in out, f"the stepless, secondless, malformed and non-record lines are skipped and counted, the not-run "
                      f"records and the lines of other kinds (a spool gate line, a logcli line) counted apart "
                      f"({out[-1:]})")

code, out = run([], "gate=x step=y seconds= result=pass\n\n")
check(code == 2 and "0 records read, 0 not run (skipped, deferred or dry), 1 skipped (no step, or no whole seconds), "
      "0 of other kinds" in out, f"only unreadable records: exit 2, nothing folded in ({code}, {out[-1:]})")

code, _ = run(["--since", "1d"], FIXTURE)
check(code == 2, f"--since with --records is refused ({code})")

for bad in ("0d", "7w"):
    code, _ = run(["--loki", "http://127.0.0.1:9", "--since", bad])
    check(code == 2, f"--since {bad} is refused ({code})")

code, out = run(["--loki", "http://u:hunter2@127.0.0.1:9"])
check(code == 2 and not any("hunter2" in line for line in out),
      f"a Loki URL with a password: exit 2, the password not printed ({code}, {out})")

env = {k: v for k, v in os.environ.items() if k != "LOKI_ADDR"}
code, _ = run([], env=env)
check(code == 2, f"no --records, no --loki and no LOKI_ADDR: exit 2 ({code})")

queries: list[dict[str, list[str]]] = []
LINES = ["gate=nixos-qa step=nixos-flake-check seconds=600 result=pass sha=5555"]


class Loki(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        queries.append(q)
        if os.environ.get("LOKI_500"):
            self.send_response(500)
            self.end_headers()
            return
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

before = time.time()
code, out = run(["--loki", url, "--since", "36h"])
spans = [(int(q["start"][0]) / 1e9, int(q["end"][0]) / 1e9) for q in queries]
check(code == 0 and len(spans) == 2 and spans[0][0] == spans[1][1] and before <= spans[0][1] <= time.time()
      and abs(spans[1][1] - spans[1][0] - 12 * 3600) < 1
      and rows(out) == ["| nixos-qa | nixos-flake-check | - | 2 | 10.0 | 10.0 | 0 |"],
      f"--since 36h: a day query from now and a 12 h one, meeting without overlap, a row per record read "
      f"({code}, {spans}, {rows(out)})")

queries.clear()
os.environ["LOKI_500"] = "1"
code, out = run(["--loki", url])
check(code == 2 and not rows(out), f"Loki answers 500: exit 2 and no table ({code}, {out[-1:]})")
del os.environ["LOKI_500"]

queries.clear()
os.environ["FULL_DAY"] = "1"
code, out = run(["--loki", url, "--since", "7d"])
check(code == 2 and len(queries) == 1 and not rows(out),
      f"a day at the line limit: exit 2 and no table, not short counts ({code}, {len(queries)} queries)")
server.shutdown()

finish()
