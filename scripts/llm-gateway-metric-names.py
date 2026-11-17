#!/usr/bin/env python3
"""The series names llm-gateway exports, from its registrations in SRC/crates/gateway/src/metrics.rs, one per line
in exposition form (`name 0`) for scripts/check-grafana-dashboards.py. prometheus-client adds _total to a counter
and _bucket, _sum and _count to a histogram. Exits non-zero if a registration's type cannot be read.
Usage: llm-gateway-metric-names.py SRC"""
import re
import sys

text = open(sys.argv[1] + "/crates/gateway/src/metrics.rs").read()
prefix = re.search(r'Registry::with_prefix\("(\w+)"\)', text).group(1)
types = dict(re.findall(r"(\w+):\s*Family<\w+,\s*(\w+)", text))
aliases = dict(re.findall(r"type (\w+) = (Counter|Gauge|Histogram)\b", text))
registrations = re.findall(r'registry\.register\(\s*"(\w+)",\s*"(?:[^"\\]|\\.)*",\s*(?:m\.)?(\w+)', text)
if not registrations or len(registrations) != text.count("registry.register("):
    sys.exit(f"llm-gateway-metric-names: read {len(registrations)} of {text.count('registry.register(')} registrations")
suffixes = {"Counter": ["_total"], "Gauge": [""], "Histogram": ["_bucket", "_sum", "_count"]}
for name, field in registrations:
    kind = aliases.get(types.get(field), types.get(field))
    if kind not in suffixes:
        sys.exit(f"llm-gateway-metric-names: {name} ({field}) has type {kind!r}")
    for s in suffixes[kind]:
        print(f"{prefix}_{name}{s} 0")
