#!/usr/bin/env python3
"""The provisioned Grafana dashboards against what the fleet exports (flake-modules/grafana-dashboards-check.nix):
each dashboard's structure; every PromQL expression, panel or variable, through promtool and every LogQL one through
logcli's parser; every metric name in an exporter's own output, a rule file's records, a Go service's metric name
literals or the OTLP allow-list; every `job` a query selects scraped by Prometheus or written to Loki by the repo; every variable
defined; and no host named by hand in a query.
Black-pi's alert and recording rules (SPEC alert_rules, YAML: run with PyYAML) are held to the same names and jobs.
Usage: check-grafana-dashboards.py SPEC.json PROMTOOL LOGCLI EXPOSITION...; exits non-zero on any FAIL. EXPOSITION is
an exporter's /metrics output; SPEC names the dashboards, the fleet's hosts, the rule files and the metric sources."""
import json
import pathlib
import re
import subprocess
import sys
import tempfile

spec = json.load(open(sys.argv[1]))
promtool, logcli = sys.argv[2], sys.argv[3]
hosts = set(spec["hosts"])
metrics = set(spec["builtin"])
for f in sys.argv[4:]:
    metrics |= {re.match(r"[A-Za-z_:][\w:]*", line).group(0) for line in open(f) if line[:1].isalpha()}
for f in spec["rule_files"]:
    metrics |= set(re.findall(r'record"?\s*:\s*"?([A-Za-z_:][\w:]*)', open(f).read()))
# a generator's whole vocabulary: its rules exist only for the results committed so far
for f in spec["record_sources"]:
    metrics |= set(re.findall(r'"([a-z_]+:[a-z_:]+)"', open(f).read()))
# a Go service's metric names as string literals in its source: the whole name, or the part after its namespace
sources = [dict(s, literals=set(open(s["literals"]).read().split())) for s in spec["sources"]]
# alloy-otlp's allow-list (codex\.(a|b)), as Prometheus names them: dots to underscores, then a unit and a suffix
otlp = set()
for group, alts in re.findall(r"(codex|claude_code)\\+\.\(([^)]*)\)", open(spec["otlp_allowlist"]).read()):
    otlp |= {group + "_" + re.sub(r"\\+\.", "_", a) for a in alts.split("|")}
# the Loki streams the repo writes: `job = "…"`, `job: "…"`, {job="…"} and alloy-otlp's service.name values
loki_jobs = set()
for f in spec["loki_job_sources"]:
    text = open(f).read()
    loki_jobs |= set(re.findall(r'\bjob\s*[=:]\s*\\?"([a-z][a-z-]*)', text))
    loki_jobs |= set(re.findall(r'"service\.name"\], "([a-z][a-z-]*)"', text))
failed = []

# PromQL's keywords, in any case
KEYWORDS = {"and", "or", "unless", "by", "without", "on", "ignoring", "group_left", "group_right", "bool", "offset",
            "inf", "nan", "atan2"}
HOST_LABELS = r"node|nodename|host|hostname|host_name|instance"
QUOTED = r'"((?:\\.|[^"\\])*)"|\'((?:\\.|[^\'\\])*)\'|`([^`]*)`'
VAR = re.compile(r"\$\{([A-Za-z_]\w*)(?::\w+)?\}|\$([A-Za-z_]\w*)|\[\[([A-Za-z_]\w*)\]\]")
SUFFIX = re.compile(r"_(total|bucket|sum|count)$")
# a Go histogram's literal is its base name; a counter's literal already ends in _total
SERIES = re.compile(r"_(bucket|sum|count)$")


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
    names = {next(g for g in m.groups()[1:] if g is not None)
             for m in re.finditer(r"__name__\s*=\s*(?:" + QUOTED + ")", e)}
    e = re.sub(QUOTED, '""', e)
    e = re.sub(r"#[^\n]*", " ", e)
    e = re.sub(r"\{[^}]*\}", " ", e)
    e = re.sub(r"\[[^\]]*\]", " ", e)
    e = re.sub(r"(?i)\b(by|without|on|ignoring|group_left|group_right)\s*\([^)]*\)", " ", e)
    e = re.sub(r"(?i)\boffset\s+\w+", " ", e)
    e = re.sub(r"(?<![\w:])\d+(\.\d+)?([eE][+-]?\d+)?", " ", e)
    for m in re.finditer(r"[A-Za-z_:][\w:]*", e):
        if m.group(0).lower() in KEYWORDS or re.match(r"\s*\(", e[m.end():]):
            continue
        names.add(m.group(0))
    return names


def known(name):
    if name in metrics:
        return True
    for s in sources:
        if name.startswith(s["prefix"]):
            short = name[len(s["strip"]):]
            # an underscore: a bare word (name, model) is quoted in any source for other reasons
            return any("_" in c and c in s["literals"] for c in {name, short, SERIES.sub("", short)})
    if name.startswith(("codex_", "claude_code_")):
        base = SUFFIX.sub("", name)
        return base in otlp or re.sub(r"_[A-Za-z]+$", "", base) in otlp
    return False


def check_expr(where, expr, variables, loki):
    for m in VAR.finditer(expr):
        name = next(g for g in m.groups() if g)
        if not name.startswith("__") and name not in variables:
            fail(where, f"undefined variable ${name} in {expr!r}")
    for m in re.finditer(r"\b(" + HOST_LABELS + r")\s*(=|!=|=~|!~)\s*(?:" + QUOTED + ")", expr):
        value = next(g for g in m.groups()[2:] if g is not None)
        if not re.fullmatch(r"\$\{?\w+\}?|[.*+]*", value):
            fail(where, f"host literal {m.group(1)}{m.group(2)}{value!r}: use the fleet variable")
    jobs = loki_jobs if loki else set(spec["scrape_jobs"])
    for m in re.finditer(r"\bjob\s*=\s*(?:" + QUOTED + ")", expr):
        value = next(g for g in m.groups() if g is not None)
        if not value.startswith("$") and value not in jobs:
            fail(where, f"job {value!r}: no {'Loki stream' if loki else 'scrape job'} by that name")
    for h in hosts:
        if re.search(r"(?<![\w-])" + re.escape(h) + r"(?![\w-])", expr):
            fail(where, f"fleet host {h} named in {expr!r}: use the fleet variable")
    if loki:
        logql.append((where, expr))
        return
    promql.append((where, expr))
    for name in sorted(metric_names(expr)):
        if not known(name):
            fail(where, f"unknown metric {name}: no exporter, record or scraped service provides it")


def check_rule(where, expr):
    """An alert or recording rule: its jobs scraped, its metric names provided (hosts may be named: a rule is per host)."""
    for m in re.finditer(r"\bjob\s*=\s*(?:" + QUOTED + ")", expr):
        value = next(g for g in m.groups() if g is not None)
        if value not in spec["scrape_jobs"]:
            fail(where, f"job {value!r}: no scrape job by that name")
    for name in sorted(metric_names(expr)):
        if not known(name):
            fail(where, f"unknown metric {name}: no exporter, record or scraped service provides it")


uids = {}
promql, logql = [], []
for f, d in sorted(spec["dashboards"].items()):
    for key in ("uid", "title", "panels"):
        if key not in d:
            fail(f, f"no {key}")
    if d.get("uid") in uids:
        fail(f, f"duplicate uid {d['uid']} (also {uids[d['uid']]})")
    uids[d.get("uid")] = f
    templating = d.get("templating", {}).get("list", [])
    variables = [v.get("name") for v in templating]
    if len(variables) != len(set(variables)):
        fail(f, f"a variable is declared twice: {variables}")
    for v in templating:
        if v.get("type") != "query":
            continue
        query = v.get("query")
        query = query.get("query", "") if isinstance(query, dict) else query or ""
        ds = v.get("datasource") or {}
        loki = (ds.get("uid") if isinstance(ds, dict) else ds) == "loki"
        m = re.fullmatch(r"\s*label_values\((.*),\s*\w+\s*\)\s*", query, re.S)
        if m:
            check_expr(f"{f} variable {v['name']}", m.group(1), variables, loki)
        elif not re.fullmatch(r"\s*label_values\(\s*\w+\s*\)\s*", query):
            fail(f"{f} variable {v['name']}", f"query {query!r} is not label_values(selector, label)")
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
            if t.get("expr") is None:
                continue
            ds = t.get("datasource") or p.get("datasource") or {}
            check_expr(where, t["expr"], variables, (ds.get("uid") if isinstance(ds, dict) else ds) == "loki")
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

# --stdin parses the query before it refuses a metric query; only a parse error is a failure
for where, expr in logql:
    r = subprocess.run([logcli, "query", "--stdin", "--quiet", substitute(expr)], input="", capture_output=True,
                       text=True)
    if "parse error" in r.stdout + r.stderr:
        fail(where, f"LogQL: {(r.stdout + r.stderr).strip()}")

rules = 0
if spec.get("alert_rules"):
    import yaml
for f in spec.get("alert_rules", []):
    for group in yaml.safe_load(open(f))["groups"]:
        for r in group["rules"]:
            rules += 1
            check_rule(f"rules {pathlib.Path(f).stem} {r.get('alert') or r.get('record')}", r["expr"])

for line in failed:
    print("FAIL: " + line)
print(f"{len(spec['dashboards'])} dashboards, {len(promql)} PromQL and {len(logql)} LogQL expressions, {rules} rules, "
      f"{len(failed)} failures")
sys.exit(1 if failed else 0)
