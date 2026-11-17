#!/usr/bin/env python3
"""Readability gates (#295): every fleet size the current docs state ("six-host", "six hosts") is the number of
entries in flake-modules/hosts.nix, and the README host table has one row per entry; and every sam.* and homelab.*
option leaf any host declares, submodule sub-options included, has a description (scripts/gate-probe.nix,
option-docs). docs/records/ is dated and out of scope. Seeded cases: wrong counts and a missing README row must be
caught, an undescribed top-level and submodule leaf declared by the probe must be reported."""
import pathlib
import re
import sys

import gate_probe

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORDS = ["two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"]
# "one host" is a scope ("one host at a time"), not a fleet size
COUNT = re.compile(r"(?<![\w-])(" + "|".join(WORDS) + r"|[2-9]|1[0-9])[- ]hosts?\b", re.IGNORECASE)
# fleet.nix is lane H's file (#295); each leaf leaves this list when it gets a description
OWED = {
    "sam.fleet.deployer", "sam.fleet.edge", "sam.fleet.gateway", "sam.fleet.hosts", "sam.fleet.hosts.address",
    "sam.fleet.hosts.extraAddresses", "sam.fleet.hosts.gpu", "sam.fleet.hosts.power", "sam.fleet.hosts.power.interface",
    "sam.fleet.hosts.power.mac", "sam.fleet.hosts.power.off", "sam.fleet.hosts.power.wake", "sam.fleet.hosts.sleeps",
    "sam.fleet.lanCidr",
}
failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


def number(token):
    return int(token) if token.isdigit() else WORDS.index(token.lower()) + 2


def wrong_counts(text, n):
    return [m.group(0) for m in COUNT.finditer(text) if number(m.group(1)) != n]


def readme_hosts(text):
    # | `lenovo-21CB001PMX` (`lenovo`) | … : the flake attribute where the row gives one, else the name
    return {m.group(2) or m.group(1) for m in re.finditer(r"^\| `([A-Za-z0-9-]+)`(?: \(`([a-z0-9-]+)`\))? \|", text, re.M)}


def undescribed(leaves):
    return {leaf["name"] for leaf in leaves if not leaf["described"]}


table = (ROOT / "flake-modules/hosts.nix").read_text()
hosts = set(re.findall(r"^    ([a-z0-9-]+) = \{", table, re.M))
check(len(hosts) >= 6 and "lenovo" in hosts, f"hosts.nix entries are read ({sorted(hosts)})")
n = len(hosts)

check(wrong_counts("a six-host fleet; all six hosts", 6) == [], "seeded: a matching count passes")
check(wrong_counts("One flake, a five-host homelab", 6) == ["five-host"], "seeded: a stale hyphenated count is caught")
check(wrong_counts("**Scale.** 5 hosts, with one host at a time", 6) == ["5 hosts"],
      "seeded: a stale numeric count is caught and `one host` is not a count")
check(wrong_counts("- 2026-11-12 Host reboot", 6) == [], "seeded: a date before `Host` is not a count")
docs = [ROOT / "README.md", ROOT / "CLAUDE.md", ROOT / "flake.nix"] + sorted((ROOT / "docs").glob("*.md"))
stale = [f"{p.relative_to(ROOT)}: {c}" for p in docs for c in wrong_counts(p.read_text(), n)]
check(not stale, f"every fleet size stated in {len(docs)} current docs is {n} ({stale})")

seeded = "| `lenovo-21CB001PMX` (`lenovo`) | Laptop | x |\n| `acer-swift` | Laptop | x |\n"
check(readme_hosts(seeded) == {"lenovo", "acer-swift"}, "seeded: README rows are read by flake attribute")
rows = readme_hosts((ROOT / "README.md").read_text())
check(rows == hosts, f"the README host table has one row per hosts.nix entry (missing {sorted(hosts - rows)}, "
      f"extra {sorted(rows - hosts)})")

P = gate_probe.section("option-docs")
check(undescribed(P["seeded"]) - OWED == {"sam.seededUndescribed", "homelab.seededDescribed.port"},
      f"seeded: an undescribed top-level and submodule leaf are reported ({sorted(undescribed(P['seeded']) - OWED)})")
leaves = {leaf["name"]: leaf for ls in P["hosts"].values() for leaf in ls}
missing = undescribed(leaves.values())
check(len(leaves) > 100 and not missing - OWED,
      f"every one of {len(leaves)} sam.*/homelab.* option leaves has a description (missing: "
      f"{ {m: leaves[m]['files'] for m in sorted(missing - OWED)} })")
check(OWED <= missing, f"the owed list holds only leaves still without one (described now: {sorted(OWED - missing)})")
print(f"owed (fleet.nix, lane H): {len(missing & OWED)} leaves without a description")

sys.exit(1 if failed else 0)
