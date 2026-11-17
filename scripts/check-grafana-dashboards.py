#!/usr/bin/env python3
"""The provisioned Grafana dashboards against what the fleet exports (flake-modules/grafana-dashboards-check.nix):
each dashboard's structure, every PromQL expression through promtool, every metric name in the exporters' own output,
the rule files' records or a scraped job's prefix, every variable defined, and no host named by hand in a query.
Usage: check-grafana-dashboards.py SPEC.json PROMTOOL EXPOSITION...; exits non-zero on any FAIL. EXPOSITION is an
exporter's /metrics output; SPEC names the dashboards, the fleet's hosts, the rule files, the scraped jobs' prefixes."""
import json
import re
import subprocess
import sys
import tempfile

spec = json.load(open(sys.argv[1]))
promtool = sys.argv[2]
hosts = set(spec["hosts"])
metrics = set(spec["builtin"])
for f in sys.argv[3:]:
    metrics |= {re.match(r"[A-Za-z_:][\w:]*", line).group(0) for line in open(f) if line[:1].isalpha()}
for f in spec["rule_files"]:
    metrics |= set(re.findall(r'record"?\s*:\s*"?([A-Za-z_:][\w:]*)', open(f).read()))
# a generator's whole vocabulary: its rules exist only for the results committed so far
for f in spec["record_sources"]:
    metrics |= set(re.findall(r'"([a-z_]+:[a-z_:]+)"', open(f).read()))
prefixes = spec["prefixes"]
failed = []

KEYWORDS = {"and", "or", "unless", "by", "without", "on", "ignoring", "group_left", "group_right", "bool", "offset",
            "inf", "nan", "Inf", "NaN", "atan2"}
HOST_LABELS = r"node|host|host_name|instance"
VAR = re.compile(r"\$\{([A-Za-z_]\w*)(?::\w+)?\}|\$([A-Za-z_]\w*)|\[\[([A-Za-z_]\w*)\]\]")


def fail(where, what):
    failed.append(f"{where}: {what}")


def walk(panels):
    for p in panels:
        yield p
        yield from walk(p.get("panels", []))


def substitute(expr):
    # Grafana's interval variables as a duration, any other variable as a label value
    expr = re.sub(r"\$\{?__(rate_interval|interval|range|auto)\}?", "5m", expr)
    return VAR.sub("x", expr)


def metric_names(expr):
    e = substitute(expr)
    e = re.sub(r'"(?:\\.|[^"\\])*"|`[^`]*`|\'(?:\\.|[^\'\\])*\'', '""', e)
    e = re.sub(r"\{[^}]*\}", " ", e)
    e = re.sub(r"\[[^\]]*\]", " ", e)
    e = re.sub(r"\b(by|without|on|ignoring|group_left|group_right)\s*\([^)]*\)", " ", e)
    e = re.sub(r"\boffset\s+\w+", " ", e)
    e = re.sub(r"(?<![\w:])\d+(\.\d+)?([eE][+-]?\d+)?", " ", e)
    names = set()
    for m in re.finditer(r"[A-Za-z_:][\w:]*", e):
        if m.group(0) in KEYWORDS or re.match(r"\s*\(", e[m.end():]):
            continue
        names.add(m.group(0))
    return names


def known(name):
    return name in metrics or any(name.startswith(p) for p in prefixes)


uids = {}
promql = []
for f, d in sorted(spec["dashboards"].items()):
    for key in ("uid", "title", "panels"):
        if key not in d:
            fail(f, f"no {key}")
    if d.get("uid") in uids:
        fail(f, f"duplicate uid {d['uid']} (also {uids[d['uid']]})")
    uids[d.get("uid")] = f
    variables = [v.get("name") for v in d.get("templating", {}).get("list", [])]
    if len(variables) != len(set(variables)):
        fail(f, f"a variable is declared twice: {variables}")
    default_ds = "prometheus"
    for v in d.get("templating", {}).get("list", []):
        if v.get("type") == "datasource" and v.get("query") == "loki":
            default_ds = "loki"
    ids = []
    for p in walk(d.get("panels", [])):
        where = f"{f} panel {p.get('id')} {p.get('title')!r}"
        ids.append(p.get("id"))
        g = p.get("gridPos", {})
        if p.get("type") is None or not all(isinstance(g.get(k), int) for k in ("h", "w", "x", "y")):
            fail(where, "no type or gridPos h/w/x/y")
        # Grafana names a target without one
        refs = [t["refId"] for t in p.get("targets", []) if "refId" in t]
        if len(refs) != len(set(refs)):
            fail(where, f"refIds repeat: {refs}")
        for t in p.get("targets", []):
            expr = t.get("expr")
            if expr is None:
                continue
            ds = t.get("datasource") or p.get("datasource") or {}
            uid = ds.get("uid") if isinstance(ds, dict) else ds
            loki = uid == "loki" or (uid in (None, "${datasource}", "$datasource") and default_ds == "loki")
            for m in VAR.finditer(expr):
                name = next(g for g in m.groups() if g)
                if not name.startswith("__") and name not in variables:
                    fail(where, f"undefined variable ${name} in {expr!r}")
            for m in re.finditer(r'\b(' + HOST_LABELS + r')\s*(=|!=|=~|!~)\s*"([^"]*)"', expr):
                if not re.fullmatch(r"\$\{?\w+\}?|[.*+]*", m.group(3)):
                    fail(where, f"host literal {m.group(1)}{m.group(2)}\"{m.group(3)}\": use the fleet variable")
            for h in hosts:
                if re.search(r"(?<![\w-])" + re.escape(h) + r"(?![\w-])", expr):
                    fail(where, f"host literal {h} in {expr!r}: use the fleet variable")
            if loki:
                continue
            promql.append((where, expr))
            for name in sorted(metric_names(expr)):
                if not known(name):
                    fail(where, f"unknown metric {name}: no exporter, record or scraped job provides it")
    if len(ids) != len(set(ids)) or None in ids:
        fail(f, "panel ids missing or repeated")

with tempfile.NamedTemporaryFile("w", suffix=".json") as rules:
    json.dump({"groups": [{"name": "dashboards", "rules": [
        {"record": f"dashboard:expr:{i}", "expr": substitute(e)} for i, (_, e) in enumerate(promql)]}]}, rules)
    rules.flush()
    r = subprocess.run([promtool, "check", "rules", rules.name], capture_output=True, text=True)
    if r.returncode != 0:
        for line in (r.stdout + r.stderr).splitlines():
            n = re.search(r"dashboard:expr:(\d+)", line)
            fail(promql[int(n.group(1))][0] if n else "promtool", f"promtool: {line.strip()}")
        if not any("promtool" in x for x in failed):
            fail("promtool", (r.stdout + r.stderr).strip())

for line in failed:
    print("FAIL: " + line)
print(f"{len(spec['dashboards'])} dashboards, {len(promql)} PromQL expressions, {len(failed)} failures")
sys.exit(1 if failed else 0)
