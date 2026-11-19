#!/usr/bin/env python3
"""The platform scorecard (pkgs/scorecard) on a fake Prometheus and Loki: a pass and a fail against the threshold, the
worst series named; no query, an empty result, an HTTP error, an error status, a NaN and a matrix each unknown with
the reason, never a pass; a metric whose record kind has nothing within its maximum age stale, and the kind table
saying so; by-hand unknown with its reading. A backend that does not answer, or is not ready, exits 2 and leaves its
metrics unknown while the other backend's are still read. The real metrics/targets.json against backends that answer
no query: every metric printed in its area, none a pass. Run as `test-scorecard.py [the packaged scorecard]`."""
from __future__ import annotations

import http.server
import json
import os
import pathlib
import socket
import subprocess
import sys
import tempfile
import threading
import urllib.parse
from typing import Any, ClassVar

from gate_probe import check, finish

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROGRAM = sys.argv[1:] or [sys.executable, str(ROOT / "pkgs/scorecard/scorecard.py")]

Answer = tuple[int, Any]


def vector(*samples: tuple[dict[str, str], str]) -> Answer:
    result = [{"metric": m, "value": [1_700_000_000, v]} for m, v in samples]
    return 200, {"status": "success", "data": {"resultType": "vector", "result": result}}


def fresh(kind: str, hours: int) -> str:
    return f'sum(count_over_time({{job="platform",kind="{kind}"}}[{hours}h]))'


class Fake(http.server.BaseHTTPRequestHandler):
    answers: ClassVar[dict[tuple[str, str], Answer]] = {}
    ready: ClassVar[dict[str, int]] = {"/-/ready": 200, "/ready": 200}

    def do_GET(self) -> None:
        url = urllib.parse.urlparse(self.path)
        if url.path in Fake.ready:
            code, body = Fake.ready[url.path], "ready"
        else:
            q = urllib.parse.parse_qs(url.query).get("query", [""])[0]
            code, payload = Fake.answers.get((url.path, q), (400, {"status": "error", "error": "no canned answer"}))
            body = payload if isinstance(payload, str) else json.dumps(payload)
        self.send_response(code)
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, *args: Any) -> None:
        pass


PROM, LOKI = "/api/v1/query", "/loki/api/v1/query"
Fake.answers = {
    (PROM, "shipping_ok"): vector(({}, "0")),
    (PROM, 'probe_success{job="blackbox"}'): vector(({"instance": "a"}, "1"), ({"instance": "b"}, "0.5")),
    (PROM, "shipping_empty"): vector(),
    (PROM, "shipping_bad"): (400, {"status": "error", "error": "parse error at char 3"}),
    (PROM, "shipping_status"): (200, {"status": "error", "error": "query timed out"}),
    (PROM, "shipping_nan"): (200, {"status": "success", "data": {"resultType": "scalar", "result": [1, "NaN"]}}),
    (PROM, "shipping_matrix"): (200, {"status": "success", "data": {"resultType": "matrix", "result": []}}),
    (LOKI, fresh("deploy", 336)): vector(({}, "3")),
    (LOKI, fresh("gate", 96)): vector(),
    (LOKI, 'sum(count_over_time({job="platform",kind="deploy"} | logfmt [1d])) or vector(0)'): vector(({}, "0")),
    (LOKI, 'sum(count_over_time({job="platform",kind="deploy"} | logfmt | result!="ok" [30d]))'): vector(({}, "2")),
}


def metric(mid: str, area: str, query: str | None, backend: str | None = None, op: str = "<=",
           value: float | None = 0) -> dict[str, Any]:
    threshold = None if query is None else ({"op": op} if value is None else {"op": op, "value": value})
    return {"id": mid, "area": area, "state": "live" if query else "new", "query": query, "backend": backend,
            "threshold": threshold, "target": f"target of {mid}"}


SEEDED = {
    "areas": {"A": "First", "B": "Second"},
    "max_age_hours": {"deploy": 336, "gate": 96},
    "metrics": [
        metric("no-query", "A", None),
        metric("passes", "A", "shipping_ok", "prometheus"),
        metric("fails", "A", 'probe_success{job="blackbox"}', "prometheus", ">=", 0.99),
        metric("empty", "A", "shipping_empty", "prometheus"),
        metric("http-error", "A", "shipping_bad", "prometheus"),
        metric("error-status", "B", "shipping_status", "prometheus"),
        metric("nan", "B", "shipping_nan", "prometheus"),
        metric("matrix", "B", "shipping_matrix", "prometheus"),
        metric("quiet-kind", "B", 'sum(count_over_time({job="platform",kind="gate"} [1d]))', "loki"),
        metric("loki-passes", "B", 'sum(count_over_time({job="platform",kind="deploy"} | logfmt [1d])) or vector(0)',
               "loki"),
        metric("by-hand", "B", 'sum(count_over_time({job="platform",kind="deploy"} | logfmt | result!="ok" [30d]))',
               "loki", "by-hand", None),
    ],
}


def run(targets: dict[str, Any] | pathlib.Path, prometheus: str, loki: str) -> tuple[int, str, dict[str, list[str]]]:
    with tempfile.TemporaryDirectory() as tmp:
        path = targets if isinstance(targets, pathlib.Path) else pathlib.Path(tmp) / "targets.json"
        if not isinstance(targets, pathlib.Path):
            path.write_text(json.dumps(targets))
        # a proxy variable would send the fake backends' localhost traffic elsewhere
        env = {k: v for k, v in os.environ.items() if "proxy" not in k.lower()}
        env.update(SCORECARD_PROMETHEUS_URL=prometheus, SCORECARD_LOKI_URL=loki)
        out = subprocess.run([*PROGRAM, str(path)], env=env, capture_output=True, text=True, timeout=60,
                             check=False)
    rows = {c[0]: c[1:] for line in out.stdout.splitlines() if line.startswith("| ") and not line.startswith("| Metric")
            and not line.startswith("| Kind") for c in [[x.strip() for x in line.strip("|").split(" | ")]]}
    return out.returncode, out.stdout + out.stderr, rows


def closed_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return int(s.getsockname()[1])


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fake)
threading.Thread(target=server.serve_forever, daemon=True).start()
url = f"http://127.0.0.1:{server.server_port}"

rc, out, rows = run(SEEDED, url, url)
verdict = {k: v[-1] for k, v in rows.items()}
check(rc == 0, f"both backends answering: exit 0 (rc {rc}) {'' if rc == 0 else out}")
check(out.index("## A. First") < out.index("| no-query ") < out.index("## B. Second") < out.index("| nan "),
      "each metric is printed in its area's table, in order")
check(rows.get("passes", [None])[0] == "0" and verdict.get("passes") == "pass",
      f"a reading within its threshold passes ({rows.get('passes')})")
check(verdict.get("fails") == "fail" and rows["fails"][0] == "worst 0.5 {instance=b} of 2",
      f"one series outside its threshold fails the metric, the worst one named ({rows.get('fails')})")
check(verdict.get("no-query") == "unknown: no query (new)", f"no query is unknown ({verdict.get('no-query')})")
check(verdict.get("empty") == "unknown: empty result", f"an empty result is unknown ({verdict.get('empty')})")
check(verdict.get("http-error") == "unknown: HTTP 400: parse error at char 3",
      f"a query the backend refuses is unknown with its error ({verdict.get('http-error')})")
check(verdict.get("error-status") == "unknown: status error: query timed out",
      f"an error status in a 200 is unknown with its error ({verdict.get('error-status')})")
check(verdict.get("nan") == "unknown: a reading is not a number", f"a NaN reading is unknown ({verdict.get('nan')})")
check((verdict.get("matrix") or "").startswith("unknown: result type 'matrix'"),
      f"a matrix is unknown ({verdict.get('matrix')})")
check(verdict.get("quiet-kind") == "stale: gate: no record in 96 h",
      f"a metric reading a kind quiet past its max age is stale ({verdict.get('quiet-kind')})")
check(rows.get("gate", [None, None])[1] == "stale: no record in 96 h"
      and rows.get("deploy", [None, None])[1] == "fresh",
      f"the kind table: gate stale, deploy fresh ({rows.get('gate')}, {rows.get('deploy')})")
check(verdict.get("loki-passes") == "pass",
      f"a Loki metric on a fresh kind is read and passes ({verdict.get('loki-passes')})")
check(verdict.get("by-hand") == "unknown: judged by hand" and rows["by-hand"][0] == "2",
      f"a by-hand target is unknown, its reading shown ({rows.get('by-hand')})")
check("Metrics: pass 2, fail 1, stale 1, unknown 7" in out, "the summary counts each verdict")

down = f"http://127.0.0.1:{closed_port()}"
rc, out, rows = run(SEEDED, down, url)
verdict = {k: v[-1] for k, v in rows.items()}
check(rc == 2 and "Unreachable: prometheus unreachable" in out, f"Prometheus not answering: exit 2, said so (rc {rc})")
check(all(verdict[m].startswith("unknown: prometheus unreachable") for m in ("passes", "fails", "empty")),
      f"its metrics are unknown, not a pass ({[verdict[m] for m in ('passes', 'fails', 'empty')]})")
check(verdict.get("loki-passes") == "pass", "Loki's metrics are still read")

Fake.ready["/ready"] = 503
rc, out, rows = run(SEEDED, url, url)
verdict = {k: v[-1] for k, v in rows.items()}
Fake.ready["/ready"] = 200
check(rc == 2 and "Unreachable: loki not ready (HTTP 503)" in out,
      f"Loki answering not ready: exit 2, said so (rc {rc})")
check(verdict.get("loki-passes", "").startswith("unknown: deploy: loki not ready")
      and rows.get("deploy", ["", ""])[1].startswith("unknown: loki not ready"),
      f"a Loki metric and its kind are unknown, not stale or a pass"
      f" ({verdict.get('loki-passes')}, {rows.get('deploy')})")

real = json.loads((ROOT / "metrics/targets.json").read_text())
rc, out, rows = run(ROOT / "metrics/targets.json", url, url)
verdicts = {m["id"]: rows.get(m["id"], [None])[-1] for m in real["metrics"]}
check(rc == 0 and all(v for v in verdicts.values()), f"the real targets: every metric printed (rc {rc}, missing "
      f"{[k for k, v in verdicts.items() if not v]})")
check(all(v.startswith("unknown") for v in verdicts.values() if v), f"no answer, no pass: every metric unknown "
      f"({sorted({v.split(':')[0] for v in verdicts.values() if v})})")
check(all(f"## {a}. {t}" in out for a, t in real["areas"].items()) and all(k in rows for k in real["max_age_hours"]),
      "the real targets: all four areas and every record kind are printed")

server.shutdown()
finish()
