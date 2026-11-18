#!/usr/bin/env python3
"""Writes seed-NAME.json (SPEC with one seeded dashboard, or one seeded rule file, added) and seed-NAME.reason per
entry of SEEDS, for flake-modules/grafana-dashboards-check.nix. Usage: seed-grafana-dashboards.py SPEC.json SEEDS.json"""
import json
import sys

spec, seeds = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
for name, s in seeds.items():
    seeded = dict(spec)
    if "dashboard" in s:
        seeded["dashboards"] = dict(spec["dashboards"], **{"seed.json": s["dashboard"]})
    if "rules" in s:
        with open(f"rules-{name}.json", "w") as f:
            json.dump(s["rules"], f)
        seeded["alert_rules"] = spec.get("alert_rules", []) + [f"rules-{name}.json"]
    with open(f"seed-{name}.json", "w") as f:
        json.dump(seeded, f)
    with open(f"seed-{name}.reason", "w") as f:
        f.write(s["reason"])
