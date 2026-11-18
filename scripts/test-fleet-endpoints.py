#!/usr/bin/env python3
"""The alert endpoint as a sam.fleet fact (modules/core/fleet.nix): every paging unit on every host (caddy-failed,
journal-collector-failed, loki-failed) pages lenovo's ntfy by sam.fleet.pageUrl, and so does each one where the
runtime-host role's sam.workers.ntfyUrl is absent (acer with it forced null, Loki and the collector on naked-pi with
no URL set). An empty URL does not evaluate, ntfy on a host other than sam.fleet.ntfy.host fails an assertion, and a
host redefining a fleet fact does not evaluate. pi-ticket's wrapper (modules/programs/cli/pi/default.nix) on every
sam.profile.pi host exports PI_TICKET_GATEWAY_URL as the gateway-api listener's URL: devenv-platform's pi-ticket has
no default for it."""

import gate_probe
from gate_probe import check, finish



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

G = P["gatewayApi"]
check((G["host"], G["port"]) == ("acer-swift", 8081) and G["url"] == f"http://{G['address']}:{G['port']}",
      f"the llm-gateway API listener is acer's 8081, its URL derived from acer's address ({G})")
gw_line = f'export PI_TICKET_GATEWAY_URL="${{PI_TICKET_GATEWAY_URL:-{G["url"]}}}"'


def names_gateway(text):
    """The export precedes the exec of devenv-platform's pi-ticket, so the script sees it."""
    lines = [ln.strip() for ln in text.splitlines()]
    run = next((i for i, ln in enumerate(lines) if ln.startswith("exec bash ") and ln.endswith("/pi-ticket \"$@\"")), None)
    return run is not None and gw_line in lines[:run]


check(sorted(P["piTicket"]) == ["acer-swift", "lenovo"], f"pi-ticket's wrapper is on the Pi hosts ({sorted(P['piTicket'])})")
for host, text in sorted(P["piTicket"].items()):
    check(names_gateway(text), f"{host}: pi-ticket's wrapper runs `{gw_line}` before its exec")
some = next(iter(P["piTicket"].values()), "")
check(not names_gateway("\n".join(ln for ln in some.splitlines() if "PI_TICKET_GATEWAY_URL" not in ln)),
      "seeded: a wrapper without the export is caught")
check(not names_gateway(some.replace(G["url"], "http://10.43.0.80:8080")), "seeded: a wrapper naming another address is caught")

S = P["seeded"]
pages_fleet("seeded: acer without sam.workers.ntfyUrl", S["acerWithoutWorkersUrl"], expected["acer-swift"])
pages_fleet("seeded: naked-pi with Loki and the collector, no URL set", S["nakedPi"], ["journal-collector-failed", "loki-failed"])
check(S["emptyUrl"] is False, "seeded: an empty homelab.journalCollector.ntfyUrl does not evaluate")
check(any("sam.fleet.ntfy.host is lenovo-21CB001PMX" in m for m in S["ntfyOffHost"]),
      f"seeded: ntfy enabled on acer fails the fleet-host assertion ({S['ntfyOffHost']})")
check(S["fleetRedefined"] is False, "seeded: a host setting sam.fleet.ntfy.port does not evaluate (read-only)")

finish()
