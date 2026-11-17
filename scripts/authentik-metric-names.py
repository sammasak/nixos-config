#!/usr/bin/env python3
"""The series Authentik exports, for flake-modules/grafana-dashboards-check.nix, one `name 0` line each: the Python
side's prometheus_client registrations in SITE/authentik (a Counter adds _total, a Histogram _bucket, _sum and
_count), and the Go server's names as they stand in its binary (its types unknown there: bare and with a
histogram's suffixes). Exits non-zero if either side yields nothing. Usage: authentik-metric-names.py SITE SERVER"""
import pathlib
import re
import sys

site, server = pathlib.Path(sys.argv[1]) / "authentik", sys.argv[2]
suffixes = {"Counter": ["_total"], "Gauge": [""], "Histogram": ["_bucket", "_sum", "_count"],
            "Summary": ["_sum", "_count"]}
python = {(kind, name) for f in site.rglob("*.py")
          for kind, name in re.findall(r'\b(Counter|Gauge|Histogram|Summary)\(\s*"(authentik_\w+)"', f.read_text())}
# Go packs its strings without separators: a name ends at its first unit or kind suffix, not at the next letter
go = set(re.findall(rb"authentik_(?:main|outpost)[a-z_]*?(?:_seconds|_total|_info|_connection|_last_update)",
                    open(server, "rb").read()))
if not python or not go:
    sys.exit(f"authentik-metric-names: {len(python)} Python and {len(go)} Go names read")
for kind, name in sorted(python):
    for s in suffixes[kind]:
        print(f"{name}{s} 0")
for name in sorted(go):
    for s in ["", "_bucket", "_sum", "_count"]:
        print(f"{name.decode()}{s} 0")
