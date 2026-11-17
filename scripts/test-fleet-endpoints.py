#!/usr/bin/env python3
"""The alert endpoint as a sam.fleet fact (modules/core/fleet.nix): every paging unit on every host (caddy-failed,
journal-collector-failed, loki-failed) pages lenovo's ntfy by sam.fleet.pageUrl, and so does each one where the
runtime-host role's sam.workers.ntfyUrl is absent (acer with it forced null, Loki and the collector on naked-pi with
no URL set). An empty URL does not evaluate, ntfy on a host other than sam.fleet.ntfy.host fails an assertion, and a
host redefining a fleet fact does not evaluate."""
import sys

import gate_probe

failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


P = gate_probe.section("fleet-endpoints")
page = P["pageUrl"]
check(page == f"http://{P['ntfyAddress']}:{P['port']}/homelab-alerts",
      f"sam.fleet.pageUrl is the ntfy host's homelab-alerts topic on its LAN address and fleet port ({page})")


def pages_fleet(where, units, want):
    got = sorted(n for n in units if n != "workers")
    check(got == sorted(want), f"{where}: its paging units are {sorted(want)} ({got})")
    for n in got:
        script = (units[n] or "").rstrip()
        check(script.endswith(f" {page}"), f"{where}: {n} pages {page} ({script[-60:]!r})")


expected = {
    "acer-swift": ["caddy-failed", "journal-collector-failed"],
    "asus-b460m": ["journal-collector-failed"],
    "black-pi": ["journal-collector-failed", "loki-failed"],
    "lenovo": ["journal-collector-failed"],
    "msi-ms7758": ["journal-collector-failed"],
    "naked-pi": [],
}
check(sorted(P["hosts"]) == sorted(expected), f"every host is probed ({sorted(P['hosts'])})")
for host, want in expected.items():
    pages_fleet(host, P["hosts"].get(host, {}), want)
runtime = sorted(h for h, u in P["hosts"].items() if u.get("workers") is not None)
check(runtime == ["acer-swift", "asus-b460m", "msi-ms7758"], f"sam.workers.ntfyUrl is set by the runtime-host role alone ({runtime})")
check(all(P["hosts"][h]["workers"] == page for h in runtime), "and is sam.fleet.pageUrl there")

S = P["seeded"]
pages_fleet("seeded: acer without sam.workers.ntfyUrl", S["acerWithoutWorkersUrl"], expected["acer-swift"])
pages_fleet("seeded: naked-pi with Loki and the collector, no URL set", S["nakedPi"], ["journal-collector-failed", "loki-failed"])
check(S["emptyUrl"] is False, "seeded: an empty homelab.journalCollector.ntfyUrl does not evaluate")
check(any("sam.fleet.ntfy.host is lenovo-21CB001PMX" in m for m in S["ntfyOffHost"]),
      f"seeded: ntfy enabled on acer fails the fleet-host assertion ({S['ntfyOffHost']})")
check(S["fleetRedefined"] is False, "seeded: a host setting sam.fleet.ntfy.port does not evaluate (read-only)")

sys.exit(1 if failed else 0)
