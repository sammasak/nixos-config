#!/usr/bin/env python3
"""Writes seed-NAME.json (SPEC with one seeded dashboard added) and seed-NAME.reason per entry of SEEDS, for
flake-modules/grafana-dashboards-check.nix. Usage: seed-grafana-dashboards.py SPEC.json SEEDS.json"""
import json
import sys

spec, seeds = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
for name, s in seeds.items():
    with open(f"seed-{name}.json", "w") as f:
        json.dump(dict(spec, dashboards=dict(spec["dashboards"], **{"seed.json": s["dashboard"]})), f)
    with open(f"seed-{name}.reason", "w") as f:
        f.write(s["reason"])
