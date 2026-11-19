#!/usr/bin/env python3
"""The measurement doc and its targets (docs/measurement.md, metrics/targets.json): every metric in the doc is in the
targets file and the reverse, with the same area, question, source, target, state and query; a live metric has a query,
a target and a dashboard panel whose queries use the same kinds and series; an in-flight or new one has no query, and
the scorecard's machine-readable backend, threshold and (Prometheus) fresh guard, which an in-flight or new one has none
of; the area names are the doc's headings; at most six per area; every kind scripts/platform-record.sh writes has a
maximum age. Seeded cases: each of those broken in a copy must be caught."""
from __future__ import annotations

import copy
import json
import pathlib
import re
import sys
from typing import Any

from gate_probe import check, finish

ROOT = pathlib.Path(__file__).resolve().parent.parent
ARGS = sys.argv[1:3] if len(sys.argv) == 3 else ["docs/measurement.md", "metrics/targets.json"]
DOC, TARGETS = (ROOT / a for a in ARGS)
HELPER = ROOT / "scripts/platform-record.sh"
DASHBOARDS = ROOT / "modules/homelab/monitoring/dashboards"
STATES = {"live", "in flight", "new"}
LIMIT = 6
FIELDS = ["area", "question", "source", "target", "state"]
OPS = {"<=", "<", ">=", ">"}
BY_HAND = "by-hand"

Metric = dict[str, Any]
Problems = dict[str, list[str]]


def doc_metrics(text: str) -> dict[str, Metric]:
    """Rows of the area tables (`| \\`id\\` | question | source | target | state |`) and the `id: query` lines of the
    fenced blocks under them."""
    rows: dict[str, Metric] = {}
    queries: dict[str, str] = {}
    area, block = None, False
    for line in text.splitlines():
        if line.startswith("## "):
            m = re.match(r"## ([A-Z])\. ", line)
            area = m.group(1) if m else None
        elif line.startswith("```"):
            block = not block
        elif area and block and ": " in line:
            mid, query = line.split(": ", 1)
            queries[mid] = query
        elif area and (m := re.match(r"\| `([a-z0-9-]+)` \| (.*) \|$", line)):
            cells = [c.strip() for c in m.group(2).split(" | ")]
            ok = len(cells) == 4
            rows[m.group(1)] = dict(zip(FIELDS[1:], cells, strict=True), area=area) if ok else {"area": area}
    for mid, row in rows.items():
        row["query"] = queries.get(mid)
    for mid in set(queries) - set(rows):
        rows[mid] = {"query": queries[mid], "orphan": True}
    return rows


def panels() -> dict[str, list[str]]:
    """`<dashboard file>: <panel title>` to that panel's query expressions, rows' nested panels included."""
    found: dict[str, list[str]] = {}

    def walk(file: str, ps: list[dict[str, Any]]) -> None:
        for p in ps:
            exprs = [t["expr"] for t in p.get("targets", []) if t.get("expr")]
            found.setdefault(f"{file}: {p.get('title')}", []).extend(exprs)
            walk(file, p.get("panels", []))

    for f in sorted(DASHBOARDS.glob("*.json")):
        walk(f.name, json.loads(f.read_text()).get("panels", []))
    return found


PROMQL_WORDS = {"by", "on", "and", "or", "unless", "without", "ignoring", "bool", "offset", "group_left", "group_right"}


def names(query: str) -> set[str]:
    """The kinds (`kind="x"`) a LogQL query reads, or the series and recording rules of a PromQL one: what is left
    once strings, selectors, ranges, grouping labels and function calls are taken out."""
    if re.search(r"\(\{|^\{", query):
        return {f'kind="{k}"' for k in re.findall(r'kind="([^"]+)"', query)}
    bare = re.sub(r'"[^"]*"|\{[^}]*\}|\[[^\]]*\]|\b(?:by|on|without|ignoring)\s*\([^)]*\)', " ", query)
    return {n for n in re.findall(r"[A-Za-z_:][\w:]*(?![\w:]*\s*\()", bare) if n not in PROMQL_WORDS}


def threshold_problems(m: Metric) -> list[str]:
    """A live metric's backend is the language its query is written in, and its threshold an operator with a number
    (or by-hand, which the scorecard reports as unknown with its reading)."""
    out = []
    logql = bool(re.search(r"\(\{|^\{", m.get("query") or ""))
    if m.get("backend") != ("loki" if logql else "prometheus"):
        out.append(f"backend {m.get('backend')!r}, but the query is {'LogQL' if logql else 'PromQL'}")
    t = m.get("threshold")
    if not isinstance(t, dict) or t.get("op") not in {*OPS, BY_HAND}:
        out.append(f"threshold {t!r} needs an op of {sorted(OPS)} or {BY_HAND!r}")
    elif t["op"] in OPS and (isinstance(t.get("value"), bool) or not isinstance(t.get("value"), int | float)):
        out.append(f"threshold {t!r} needs a number")
    return out


def fresh_problems(m: Metric, everywhere: str) -> list[str]:
    """A Loki metric is kept fresh by its record kinds' max ages; a Prometheus one by its own `fresh` query, which
    returns nothing once the source stops (a long-window average still holds old samples), and reads only series a
    dashboard already shows."""
    guard = m.get("fresh")
    if m.get("backend") == "loki":
        return [] if guard is None else ["a Loki metric with a fresh guard: its record kinds' max ages keep it fresh"]
    if not isinstance(guard, str) or not guard.strip():
        return ["a live Prometheus metric without a fresh query"]
    unshown = sorted(n for n in names(guard) if not re.search(rf"(?<![\w:]){re.escape(n)}(?![\w:])", everywhere))
    return [f"its fresh query reads series no dashboard shows {unshown}"] if unshown else []


def problems(doc: dict[str, Metric], headings: list[str], targets: dict[str, Any], kinds: set[str],
             shown: dict[str, list[str]]) -> Problems:
    keys = ["listed", "same", "live", "unknown", "threshold", "fresh", "areas", "changed", "limit", "max_age", "kinds"]
    out: Problems = {k: [] for k in keys}
    metrics = {m["id"]: m for m in targets["metrics"]}
    everywhere = " ".join(e for exprs in shown.values() for e in exprs)
    out["listed"] += [f"{i} in the doc, not in the targets" for i in sorted(set(doc) - set(metrics))]
    out["listed"] += [f"{i} in the targets, not in the doc" for i in sorted(set(metrics) - set(doc))]
    out["listed"] += [f"{i}: a query line with no table row" for i, r in doc.items() if r.get("orphan")]
    for mid in sorted(set(doc) & set(metrics)):
        m, row = metrics[mid], doc[mid]
        out["same"] += [f"{mid}.{f}: doc {row.get(f)!r}, targets {m.get(f)!r}" for f in [*FIELDS, "query"]
                        if row.get(f) != m.get(f)]
    for mid, m in metrics.items():
        if m.get("state") not in STATES:
            out["unknown"].append(f"{mid}: state {m.get('state')!r} is none of {sorted(STATES)}")
        elif m["state"] != "live":
            if m.get("query") is not None:
                out["unknown"].append(f"{mid}: {m['state']} but has a query; only a live metric names a series")
            if m.get("backend") is not None or m.get("threshold") is not None or m.get("fresh") is not None:
                out["threshold"].append(f"{mid}: {m['state']} but has a backend, threshold or fresh guard")
            continue
        out["threshold"] += [f"{mid}: {e}" for e in threshold_problems(m)]
        out["fresh"] += [f"{mid}: {e}" for e in fresh_problems(m, everywhere)]
        if not m.get("query") or not m.get("target") or not m.get("panels"):
            out["live"].append(f"{mid}: live without a query, a target or a panel")
            continue
        missing = [p for p in m["panels"] if p not in shown]
        if missing:
            out["live"].append(f"{mid}: no such dashboard panel {missing}")
            continue
        exprs = " ".join(e for p in m["panels"] for e in shown[p])
        unshown = sorted(n for n in names(m["query"]) if not re.search(rf"(?<![\w:]){re.escape(n)}(?![\w:])", exprs))
        out["live"] += [f"{mid}: its panels never read {unshown}"] if unshown else []
        out["kinds"] += [f"{mid}: unknown {k}" for k in sorted(set(re.findall(r'kind="([^"]+)"', m["query"])) - kinds)]
    for mid, m in metrics.items():
        tc = m.get("target_changed") or {}
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", str(tc.get("date"))) or not tc.get("reason"):
            out["changed"].append(f"{mid}: target_changed needs a date and a reason ({tc})")
    titles = targets.get("areas", {})
    unnamed = {m.get("area") for m in metrics.values()} - set(titles)
    out["areas"] += [f"area {a}: no name in the targets' areas" for a in sorted(unnamed)]
    out["areas"] += [f"area {a}: the doc has no heading '## {a}. {t}'" for a, t in sorted(titles.items())
                     if not any(h.startswith(f"## {a}. {t}") for h in headings)]
    per_area: dict[str, int] = {}
    for m in metrics.values():
        per_area[m.get("area", "?")] = per_area.get(m.get("area", "?"), 0) + 1
    out["limit"] += [f"area {a}: {n} metrics, at most {LIMIT}" for a, n in sorted(per_area.items()) if n > LIMIT]
    ages = targets.get("max_age_hours", {})
    out["max_age"] += [f"{k}: no max_age_hours" for k in sorted(kinds - set(ages))]
    out["max_age"] += [f"{k}: a max age for a kind the helper does not write" for k in sorted(set(ages) - kinds)]
    out["max_age"] += [f"{k}: {v!r} is not a positive number of hours" for k, v in sorted(ages.items())
                       if not isinstance(v, int) or isinstance(v, bool) or v <= 0]
    return out


case = re.search(r"case \$kind in\n\s*([a-z| -]+)\)", HELPER.read_text())
kinds = set(case.group(1).replace(" ", "").split("|")) if case else set()
check(len(kinds) >= 8, f"the helper's kind vocabulary is read ({sorted(kinds)})")
doc = doc_metrics(DOC.read_text())
targets = json.loads(TARGETS.read_text())
shown = panels()
n = len(targets["metrics"])
check(len(doc) == n > 0, f"{len(doc)} metrics in the doc, {n} in the targets")

DESCRIBED = {
    "listed": "every metric in the doc is in the targets file and the reverse",
    "same": "doc and targets agree on area, question, source, target, state and query",
    "live": "every live metric has a query, a target and a panel that reads the same kinds and series",
    "unknown": "every metric has a known state, and only a live one has a query",
    "threshold": "a live metric's backend is its query's language and its threshold an operator with a number; "
                 "an in-flight or new one has neither",
    "fresh": "a live Prometheus metric has a fresh query on series a dashboard shows; a Loki one has none",
    "areas": "every area has a name in the targets, and that name heads its section of the doc",
    "changed": "every target says when it last changed and why",
    "limit": f"at most {LIMIT} metrics per area",
    "max_age": "every kind the helper writes has a maximum age, and only those",
    "kinds": "a live query reads only kinds the helper writes",
}
headings = [h for h in DOC.read_text().splitlines() if h.startswith("## ")]
found = problems(doc, headings, targets, kinds, shown)
for key, what in DESCRIBED.items():
    check(not found[key], f"{what} ({found[key]})" if found[key] else what)

def seeded(name: str, key: str, edit_targets: Any = None, edit_doc: Any = None) -> None:
    t, d = copy.deepcopy(targets), copy.deepcopy(doc)
    if edit_targets:
        edit_targets(t)
    if edit_doc:
        edit_doc(d)
    got = problems(d, headings, t, kinds, shown)[key]
    check(bool(got), f"seeded: {name} is caught by '{key}' ({got[:1]})")


live = next(m for m in targets["metrics"] if m["state"] == "live")
other = next(m for m in targets["metrics"] if m["state"] != "live")
by = {m["id"]: i for i, m in enumerate(targets["metrics"])}


def with_metric(mid: str, **change: Any) -> Any:
    return lambda t: t["metrics"][by[mid]].update(change)


seeded("a metric missing from the targets", "listed", lambda t: t["metrics"].pop(by[live["id"]]))
seeded("a metric missing from the doc", "listed", edit_doc=lambda d: d.pop(other["id"]))
seeded("a target edited in one place only", "same", with_metric(live["id"], target="anything"))
seeded("a live metric without a query", "live", with_metric(live["id"], query=None))
seeded("a live metric whose panel does not exist", "live",
       with_metric(live["id"], panels=["fleet.json: No such panel"]))
seeded("a live query its panel never reads", "live",
       with_metric(live["id"], query='sum(up{job="x"}) + shipping_made_up'))
seeded("an in-flight or new metric with a made-up query", "unknown", with_metric(other["id"], query="shipping_made_up"))
seeded("an unknown state", "unknown", with_metric(other["id"], state="planned"))
seeded("a target with no reason", "changed", with_metric(live["id"], target_changed={"date": "2026-11-19"}))
seeded("a seventh metric in an area", "limit", lambda t: t["metrics"].append(dict(live, id="extra")))
seeded("a live metric without a threshold", "threshold", with_metric(live["id"], threshold=None))
seeded("a threshold with an unknown operator", "threshold", with_metric(live["id"], threshold={"op": "~", "value": 1}))
seeded("a threshold without a number", "threshold", with_metric(live["id"], threshold={"op": "<=", "value": "0"}))
seeded("a LogQL query sent to Prometheus", "threshold",
       with_metric(next(m["id"] for m in targets["metrics"] if m.get("backend") == "loki"), backend="prometheus"))
seeded("an in-flight or new metric with a threshold", "threshold",
       with_metric(other["id"], threshold={"op": "<=", "value": 0}))
prom = next(m["id"] for m in targets["metrics"] if m.get("backend") == "prometheus")
loki = next(m["id"] for m in targets["metrics"] if m.get("backend") == "loki")
seeded("a live Prometheus metric without a fresh query", "fresh", with_metric(prom, fresh=None))
seeded("a fresh query on a series no dashboard shows", "fresh",
       with_metric(prom, fresh="time() - max(timestamp(made_up)) < 900"))
seeded("a Loki metric with a fresh guard", "fresh", with_metric(loki, fresh="up"))
seeded("an in-flight or new metric with a fresh guard", "threshold", with_metric(other["id"], fresh="up"))
seeded("an area renamed in the targets only", "areas", lambda t: t["areas"].update(A="Somewhere else"))
seeded("a kind without a max age", "max_age", lambda t: t["max_age_hours"].pop(min(kinds)))
seeded("a max age of zero", "max_age", lambda t: t["max_age_hours"].update({min(kinds): 0}))
seeded("a live query on a kind the helper never writes", "kinds",
       with_metric(live["id"], query='sum(count_over_time({job="platform",kind="deploys"} [1d]))'))

finish()
