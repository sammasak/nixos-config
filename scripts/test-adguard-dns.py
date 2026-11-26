"""lenovo's AdGuard as it answers the LAN (modules/homelab/adguardhome.nix, nixos-config#503): it does not answer from
the host's /etc/hosts, which maps lenovo's own name to 127.0.0.2, every fleet host's name answers its fleet address,
every listener's inside name (sam.fleet.zone) its serving host's, and evaluation fails on either way of serving a fleet
name as loopback, on a hand-written rewrite in the inside zone and on an edge site for an inside name."""

import gate_probe
from gate_probe import check, finish



P = gate_probe.section("adguard-dns")
fleet, F = P["fleet"], P["failing"]
check(P["hostsfile"] is False, f"AdGuard does not answer from lenovo's /etc/hosts (dns.hostsfile_enabled {P['hostsfile']})")
answers = {}
for r in P["rewrites"]:
    answers.setdefault(r["domain"], []).append(r["answer"])
wrong = {n: answers.get(n) for n, a in fleet.items() if answers.get(n) != [a]}
check(fleet and not wrong, f"every fleet name answers its fleet address, once (wrong: {wrong})")
inside = {k: v for k, v in P["inside"].items() if answers.get(v["dnsName"]) != [v["address"]]}
check(len(P["inside"]) >= 10 and not inside and all(v["dnsName"].endswith("." + P["zone"]) for v in P["inside"].values()),
      f"every listener and ntfy has its inside name, answering its serving host's address once (wrong: {inside})")
check(not any(d == P["zone"] or d.endswith("." + P["zone"]) for d in answers if d not in {v["dnsName"] for v in P["inside"].values()}),
      f"no rewrite in {P['zone']} but the listeners' own")
check(any("homelab.dns.rewrites names " + P["zone"] in m for m in F["zoneRewrite"]),
      f"seeded: a hand-written rewrite in the inside zone fails evaluation ({F['zoneRewrite']})")
check(any("loki." + P["zone"] + " is in sam.fleet.zone" in m for m in F["edgeSite"]),
      f"seeded: an edge site for an inside name fails evaluation ({F['edgeSite']})")
mine = [m for m in F["lenovo"] if "adguardhome.nix" in m]
check(mine == [], f"lenovo fails no AdGuard assertion ({mine})")
hosts = ("modules/homelab/adguardhome.nix: AdGuard answers the LAN from this host's /etc/hosts, which maps "
         "lenovo-21CB001PMX to loopback (nixos-config#503): keep dns.hostsfile_enabled false.")
check(hosts in F["hostsfileOn"], f"seeded: AdGuard answering from /etc/hosts fails evaluation ({F['hostsfileOn']})")
rewrite = ("modules/homelab/adguardhome.nix: a DNS rewrite serves the fleet host acer-swift as loopback; "
           "every fleet name answers its sam.fleet address.")
check(rewrite in F["loopbackRewrite"], f"seeded: a rewrite of a fleet name to loopback fails evaluation ({F['loopbackRewrite']})")

finish()
