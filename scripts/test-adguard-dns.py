"""lenovo's AdGuard as it answers the LAN (modules/homelab/adguardhome.nix, nixos-config#503): it does not answer from
the host's /etc/hosts, which maps lenovo's own name to 127.0.0.2, every fleet host's name answers its fleet address,
and evaluation fails on either way of serving a fleet name as loopback."""
import sys

import gate_probe

failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


P = gate_probe.section("adguard-dns")
fleet, F = P["fleet"], P["failing"]
check(P["hostsfile"] is False, f"AdGuard does not answer from lenovo's /etc/hosts (dns.hostsfile_enabled {P['hostsfile']})")
answers = {}
for r in P["rewrites"]:
    answers.setdefault(r["domain"], []).append(r["answer"])
wrong = {n: answers.get(n) for n, a in fleet.items() if answers.get(n) != [a]}
check(fleet and not wrong, f"every fleet name answers its fleet address, once (wrong: {wrong})")
mine = [m for m in F["lenovo"] if "adguardhome.nix" in m]
check(mine == [], f"lenovo fails no AdGuard assertion ({mine})")
hosts = ("modules/homelab/adguardhome.nix: AdGuard answers the LAN from this host's /etc/hosts, which maps "
         "lenovo-21CB001PMX to loopback (nixos-config#503): keep dns.hostsfile_enabled false.")
check(hosts in F["hostsfileOn"], f"seeded: AdGuard answering from /etc/hosts fails evaluation ({F['hostsfileOn']})")
rewrite = ("modules/homelab/adguardhome.nix: a DNS rewrite serves the fleet host acer-swift as loopback; "
           "every fleet name answers its sam.fleet address.")
check(rewrite in F["loopbackRewrite"], f"seeded: a rewrite of a fleet name to loopback fails evaluation ({F['loopbackRewrite']})")

sys.exit(1 if failed else 0)
