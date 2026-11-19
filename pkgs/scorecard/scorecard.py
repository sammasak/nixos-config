#!/usr/bin/env python3
"""The platform scorecard (docs/measurement.md): every metric in metrics/targets.json read from Prometheus or Loki and
printed per area as metric, reading, target and verdict, then each record kind's freshness. A metric without a query,
a failed or empty query, or a reading that is not a number is unknown, never a pass; a metric reading a record kind
that has gone quiet past its maximum age is stale. Exits 2 when Prometheus or Loki cannot be reached."""

from __future__ import annotations

import argparse
import json
import math
import operator
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any

DEFAULT_LOKI = "http://192.168.10.137:3100"  # held to sam.fleet.loki.url by scripts/test-fleet-contract.py
DEFAULT_PROMETHEUS = "http://192.168.10.137:9090"  # held to sam.fleet.listeners.prometheus by the same test
PATHS = {"prometheus": "/api/v1/query", "loki": "/loki/api/v1/query"}
READY = {"prometheus": "/-/ready", "loki": "/ready"}
TIMEOUT = 10
OPS: dict[str, Callable[[float, float], bool]] = {"<=": operator.le, "<": operator.lt, ">=": operator.ge,
                                                  ">": operator.gt}
BY_HAND = "by-hand"
Series = list[tuple[dict[str, str], float]]


class Unreachable(Exception):
    """The backend did not answer at all: no connection, a timeout."""


class QueryFailed(Exception):
    """The backend answered, but not with a vector or scalar of numbers."""


@dataclass
class Row:
    name: str
    reading: str
    target: str
    verdict: str
    reason: str = ""


@dataclass
class Backends:
    urls: dict[str, str]
    down: dict[str, str] = field(default_factory=dict)

    def probe(self) -> None:
        """Each backend's readiness endpoint: no answer, or an answer other than 200, marks it down for the run."""
        for backend, path in READY.items():
            try:
                with urllib.request.urlopen(f"{self.urls[backend]}{path}", timeout=TIMEOUT):
                    pass
            except urllib.error.HTTPError as e:
                self.down[backend] = f"{backend} not ready (HTTP {e.code})"
            except (urllib.error.URLError, OSError) as e:
                self.down[backend] = f"{backend} unreachable ({getattr(e, 'reason', e)})"

    def read(self, backend: str, query: str) -> Series:
        """One instant query. After a backend is found unreachable it is not tried again in this run."""
        if backend in self.down:
            raise Unreachable(self.down[backend])
        url = f"{self.urls[backend]}{PATHS[backend]}?{urllib.parse.urlencode({'query': query})}"
        try:
            with urllib.request.urlopen(url, timeout=TIMEOUT) as r:
                body = json.load(r)
        except urllib.error.HTTPError as e:
            raise QueryFailed(f"HTTP {e.code}: {error_text(e.read())}") from None
        except (urllib.error.URLError, OSError) as e:
            self.down[backend] = f"{backend} unreachable ({getattr(e, 'reason', e)})"
            raise Unreachable(self.down[backend]) from None
        except json.JSONDecodeError:
            raise QueryFailed("the answer is not JSON") from None
        return series(body)


def error_text(raw: bytes) -> str:
    try:
        return str(json.loads(raw).get("error", "no error text"))
    except (json.JSONDecodeError, AttributeError):
        return raw.decode(errors="replace").strip()[:200] or "no error text"


def series(body: Any) -> Series:
    if not isinstance(body, dict) or body.get("status") != "success":
        raise QueryFailed(f"status {body.get('status') if isinstance(body, dict) else '?'}: "
                          f"{body.get('error', 'no error text') if isinstance(body, dict) else 'not an object'}")
    data = body.get("data", {})
    try:
        if data.get("resultType") == "scalar":
            return [({}, float(data["result"][1]))]
        if data.get("resultType") == "vector":
            return [(dict(s.get("metric", {})), float(s["value"][1])) for s in data["result"]]
    except (KeyError, IndexError, TypeError, ValueError) as e:
        raise QueryFailed(f"a malformed {data.get('resultType')} ({e})") from None
    raise QueryFailed(f"result type {data.get('resultType')!r}, not a vector or scalar")


def kinds_of(query: str) -> list[str]:
    return sorted(set(re.findall(r'kind="([^"]+)"', query)))


def number(v: float) -> str:
    return str(int(v)) if v == int(v) else f"{v:.4g}"


def labels(metric: dict[str, str]) -> str:
    return "{" + ",".join(f"{k}={v}" for k, v in sorted(metric.items()) if k != "__name__") + "}"


def freshness(kinds: dict[str, int], backends: Backends) -> dict[str, tuple[str, str]]:
    """Each record kind: fresh when Loki holds a record of it within its maximum age, stale when it holds none."""
    out: dict[str, tuple[str, str]] = {}
    for kind, hours in sorted(kinds.items()):
        try:
            got = backends.read("loki", f'sum(count_over_time({{job="platform",kind="{kind}"}}[{hours}h]))')
        except (Unreachable, QueryFailed) as e:
            out[kind] = ("unknown", str(e))
            continue
        quiet = not got or all(v == 0 for _, v in got)
        out[kind] = ("stale", f"no record in {hours} h") if quiet else ("fresh", "")
    return out


def evaluate(m: dict[str, Any], fresh: dict[str, tuple[str, str]], backends: Backends) -> Row:
    row = Row(m["id"], "-", m["target"], "unknown")
    if m.get("query") is None:
        row.reason = f"no query ({m['state']})"
        return row
    quiet = [k for k in kinds_of(m["query"]) if fresh.get(k, ("unknown", ""))[0] != "fresh"]
    if quiet:
        stale = [k for k in quiet if fresh.get(k, ("unknown", ""))[0] == "stale"]
        row.verdict = "stale" if stale else "unknown"
        row.reason = "; ".join(f"{k}: {fresh.get(k, ('unknown', 'no maximum age'))[1]}" for k in quiet)
        return row
    try:
        got = backends.read(m["backend"], m["query"])
    except (Unreachable, QueryFailed) as e:
        row.reason = str(e)
        return row
    if not got:
        row.reason = "empty result"
        return row
    if any(math.isnan(v) or math.isinf(v) for _, v in got):
        row.reason = "a reading is not a number"
        return row
    threshold = m["threshold"]
    worst = (max if threshold["op"] in ("<=", "<", BY_HAND) else min)(got, key=lambda s: s[1])
    row.reading = number(worst[1]) if len(got) == 1 else f"worst {number(worst[1])} {labels(worst[0])} of {len(got)}"
    if threshold["op"] == BY_HAND:
        row.reason = "judged by hand"
        return row
    ok = all(OPS[threshold["op"]](v, float(threshold["value"])) for _, v in got)
    row.verdict = "pass" if ok else "fail"
    return row


def cell(text: str) -> str:
    return text.replace("|", "\\|")


def render(targets: dict[str, Any], rows: list[Row], fresh: dict[str, tuple[str, str]], backends: Backends) -> str:
    when = datetime.now(UTC).strftime("%Y-%m-%d %H:%M UTC")
    out = [f"# Platform scorecard, {when}", "",
           f"Prometheus {backends.urls['prometheus']}, Loki {backends.urls['loki']}", ""]
    by_id = {r.name: r for r in rows}
    for area, title in targets["areas"].items():
        out += [f"## {area}. {title}", "", "| Metric | Reading | Target | Verdict |", "|---|---|---|---|"]
        for m in (m for m in targets["metrics"] if m["area"] == area):
            r = by_id[m["id"]]
            verdict = f"{r.verdict}: {r.reason}" if r.reason else r.verdict
            out.append(f"| {r.name} | {cell(r.reading)} | {cell(r.target)} | {cell(verdict)} |")
        out.append("")
    out += ["## Record kinds", "", "| Kind | Max age | Verdict |", "|---|---|---|"]
    for kind, (verdict, reason) in fresh.items():
        shown = f"{verdict}: {reason}" if reason else verdict
        out.append(f"| {kind} | {targets['max_age_hours'][kind]} h | {cell(shown)} |")
    counts = {v: sum(r.verdict == v for r in rows) for v in ("pass", "fail", "stale", "unknown")}
    out += ["", "Metrics: " + ", ".join(f"{v} {n}" for v, n in counts.items())]
    out += [f"Unreachable: {reason}" for reason in backends.down.values()]
    return "\n".join(out) + "\n"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0] if __doc__ else None)
    parser.add_argument("targets", nargs="?", default="metrics/targets.json", help="the targets file")
    args = parser.parse_args(argv)
    with open(args.targets) as f:
        targets = json.load(f)
    backends = Backends({
        "prometheus": os.environ.get("SCORECARD_PROMETHEUS_URL", DEFAULT_PROMETHEUS).rstrip("/"),
        "loki": os.environ.get("SCORECARD_LOKI_URL", DEFAULT_LOKI).rstrip("/"),
    })
    backends.probe()
    fresh = freshness(targets["max_age_hours"], backends)
    rows = [evaluate(m, fresh, backends) for m in targets["metrics"]]
    sys.stdout.write(render(targets, rows, fresh, backends))
    return 2 if backends.down else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
