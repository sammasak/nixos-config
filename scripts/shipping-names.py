#!/usr/bin/env python3
"""Every metric the shipping rules, the Shipping dashboard and the policy's tunedBy expressions name is one the
collector emits (scripts/shipping-metrics.py --list), one the rules record, up or ALERTS: a typo or a series
the collector dropped fails the build instead of drawing an empty panel or an alert that can never fire.

Usage: shipping-names.py EMITTED RULES.json DASHBOARD.json POLICY.json   (exit 1 and the unknown names on a miss)"""
import json
import re
import sys

# node-exporter's up, and Prometheus's own alert series the policy's for and quiet hours are read against
EXTERNAL = {"up", "ALERTS"}
KEYWORDS = {"and", "or", "unless", "by", "on", "without", "ignoring", "group_left", "group_right", "offset", "bool",
            "inf", "nan"}


def names(expr):
    e = re.sub(r'"(?:[^"\\]|\\.)*"', "", expr)
    e = re.sub(r"\{[^}]*\}", "", e)
    e = re.sub(r"\[[^\]]*\]", "", e)
    e = re.sub(r"\b(by|on|without|ignoring|group_left|group_right)\s*\([^)]*\)", "", e)
    e = re.sub(r"\boffset\s+\w+", "", e)
    found = set()
    for m in re.finditer(r"(?<![\w.$])([a-zA-Z_:][a-zA-Z0-9_:]*)(\s*\()?", e):
        if not m.group(2) and m.group(1).lower() not in KEYWORDS:
            found.add(m.group(1))
    return found


def main(emitted, rules, dashboard, policy):
    known = set(open(emitted).read().split()) | EXTERNAL
    groups = json.load(open(rules))["groups"]
    known |= {r["record"] for g in groups for r in g["rules"] if "record" in r}
    exprs = [(f"rule {r.get('alert') or r.get('record')}", r["expr"]) for g in groups for r in g["rules"]]

    def targets(panels):
        for p in panels:
            yield from targets(p.get("panels", []))
            for t in p.get("targets", []):
                yield f"panel {p.get('title')!r}", t["expr"]
    exprs += list(targets(json.load(open(dashboard))["panels"]))

    def leaves(v, path):
        if isinstance(v, dict) and "tunedBy" in v:
            yield f"policy {path}", v["tunedBy"]
        elif isinstance(v, dict):
            for k, w in v.items():
                yield from leaves(w, f"{path}.{k}" if path else k)
    exprs += list(leaves(json.load(open(policy)), ""))

    bad = [(where, n) for where, e in exprs for n in sorted(names(e) - known)]
    for where, n in bad:
        print(f"shipping-names: {where} names {n}, which the collector does not emit and no rule records")
    print(f"shipping-names: {len(exprs)} expressions, {len(bad)} unknown name(s)")
    return 1 if bad or not exprs else 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
