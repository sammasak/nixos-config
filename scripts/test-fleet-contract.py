#!/usr/bin/env python3
"""The fleet's ntfy and Loki ports and its host list, held to their definitions: no tracked file but
modules/core/fleet.nix names either port (one allowlisted line, with its reason), ntfy or Loki on a port off its
sam.fleet fact fails an assertion, every host's rendered firewall admits each sam.fleet listener's port from exactly
its callers' addresses and opens nothing the listeners and public entries do not list (an open port, an upstream
openFirewall, a stray rule and a trusted interface each fail evaluation), each listener's service binds its port, and
lenovo's sam.herdr.machines and jump hosts must be the runtime hosts of flake-modules/hosts.nix: one left out, one the
table no longer has, and the table with asus-b460m removed each fail evaluation; a collector on a host without a fleet
address fails too."""
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import tomllib

import gate_probe
from gate_probe import check, finish

ROOT = pathlib.Path(__file__).resolve().parent.parent


P = gate_probe.section("fleet-contract")
ports = P["ports"]
check(sorted(ports) == ["loki", "ntfy"] and all(isinstance(p, int) for p in ports.values()), f"the fleet's ports are read {ports}")

# (path, port name, text the line must contain) -> why that one line may keep the literal
ALLOWED = {
    ("scripts/platform-record.sh", "loki", "${PLATFORM_LOKI_URL:-http://"):
        "run from the Justfile without Nix; test-platform-records.py holds its default to sam.fleet.loki",
}


def literals(files):
    """files: [(path, text)] -> [(path, line number, port name, line)] naming a fleet port outside its definition"""
    found = []
    for path, text in files:
        for n, line in enumerate(text.splitlines(), 1):
            for name, port in ports.items():
                if not re.search(rf"(?<![0-9]){port}(?![0-9])", line):
                    continue
                if path == "modules/core/fleet.nix" and line.strip() == f"port = {port};":
                    continue
                if any((path, name) == (p, k) and marker in line for p, k, marker in ALLOWED):
                    continue
                found.append((path, n, name, line.strip()))
    return found


tracked = subprocess.run(["git", "-C", str(ROOT), "ls-files"], check=True, stdout=subprocess.PIPE, text=True).stdout.split()
files = [(p, (ROOT / p).read_text(errors="ignore")) for p in tracked
         if not p.endswith(".md") and p != "flake.lock" and (ROOT / p).is_file()]
check(len(files) > 100 and any(p == "modules/core/fleet.nix" for p, _ in files), f"the tracked tree is read ({len(files)} files)")
defined = [p for p, t in files if p == "modules/core/fleet.nix" for port in ports.values() if f"port = {port};" in t]
check(len(defined) == 2, "modules/core/fleet.nix defines both ports")
hits = literals(files)
check(hits == [], "no tracked file but fleet.nix names the ntfy or Loki port: " + "; ".join(f"{p}:{n} ({k}) {l}" for p, n, k, l in hits))
for (path, name, marker), why in ALLOWED.items():
    lines = [l for l in dict(files).get(path, "").splitlines() if re.search(rf"(?<![0-9]){ports[name]}(?![0-9])", l)]
    check(len(lines) == 1 and marker in lines[0], f"allowlisted {path} names the {name} port on its one marked line only ({why})")
seeded = literals(files + [("modules/homelab/x.nix", f'  listen = ":{ports["ntfy"]}";'),
                           ("scripts/platform-record.sh", f'curl http://loki:{ports["loki"]}/ready')])
check([(p, k) for p, _, k, _ in seeded] == [("modules/homelab/x.nix", "ntfy"), ("scripts/platform-record.sh", "loki")],
      f"seeded: a module naming the ntfy port, and a second Loki literal in the allowlisted script, are found ({seeded})")

F = P["failing"]
check(len(F["hosts"]) >= 6 and all(m == [] for m in F["hosts"].values()), f"every host passes its assertions ({F['hosts']})")
check(any("homelab.ntfy.port 2587 is not sam.fleet.ntfy.port" in m for m in F["ntfyPort"]),
      f"seeded: homelab.ntfy.port = 2587 on lenovo fails ({F['ntfyPort']})")
check(any("homelab.loki.port 3101 is not sam.fleet.loki.port" in m for m in F["lokiPort"]),
      f"seeded: homelab.loki.port = 3101 on black-pi fails ({F['lokiPort']})")

# Every host's rendered rules, read here without the Nix check (modules/core/network.nix): per listener port the
# accepted sources are its callers' addresses, once each; every other accepting line is loopback or a lan public entry.
# A cross-read of accept lines only: unhooking, flushing and policy rules are the Nix check's alone.
L, PUB, FW, ADDR = P["listeners"], P["public"], P["firewall"], P["addresses"]
RULE = re.compile(r"^iptables -w -A nixos-fw -s (\S+) -p (tcp|udp) --dport ([0-9]+) -j nixos-fw-accept$")
INPUT_ACCEPT = re.compile(r"(-j|-g|--jump|--goto)(\s+|=)?(nixos-fw-accept|ACCEPT|\$)|(^|\s)(-g|--goto)(\s|=)|-[AI] +(nixos-fw|INPUT) .*-j +RETURN")
LOOPBACK = re.compile(r"(^|\s)(-i|--in-interface)\s+lo(\s|$)")
FORWARD = re.compile(r"-[AI] +(FORWARD|nixos-filter-forward|dev-env-forward)( |$)|-t +(nat|mangle|raw)( |$)")
mine = lambda host: [p for p in PUB if p["host"] in (None, host)]
check(len(FW) >= 6 and all(fw["enable"] and fw["backend"] == "iptables" for fw in FW.values()),
      f"every host runs the iptables firewall, the backend these checks read ({ {h: fw['backend'] for h, fw in FW.items()} })")
check(all(p["why"].strip() for p in PUB) and "loki" in L and L["loki"]["from"] == sorted(h for h in ADDR if h != "black-pi"),
      f"every public entry gives its reason, and Loki's callers are every other fleet host ({L.get('loki')})")
for host, fw in sorted(FW.items()):
    lines = [c.strip().replace("'", "").replace('"', "") for l in fw["extraCommands"].replace("\\\n", " ").splitlines()
             for c in re.split(r";|&&|\|\|", l)]
    accepted = [l for l in lines if INPUT_ACCEPT.search(l) and not FORWARD.search(l) and not (LOOPBACK.search(l) and "!" not in l)]
    scoped = [RULE.match(l) for l in accepted]
    want = sorted((a, l["proto"], l["port"]) for l in L.values() if l["host"] == host for h in l["from"] for a in ADDR[h])
    got = sorted((m[1], m[2], int(m[3])) for m in scoped if m and (m[2], int(m[3])) in {(l["proto"], l["port"]) for l in L.values() if l["host"] == host})
    rest = [l for l, m in zip(accepted, scoped) if not m or (m[1], m[2], int(m[3])) not in want]
    lan = [l for l in rest if (m := RULE.match(l)) and m[1] == P["lanCidr"]
           and any(p["lan"] and p["port"] == int(m[3]) and p["proto"] == m[2] for p in mine(host))]
    check(got == want, f"{host} admits each listener port from exactly its callers' addresses ({got} vs {want})")
    check(rest == lan, f"{host} accepts nothing else but lan public entries: {[l for l in rest if l not in lan]}")
    opened = [(i, proto, port) for i, sc in [(None, fw)] + list(fw["interfaces"].items()) for proto in ("tcp", "udp")
              for port in sc[f"allowed{proto.upper()}Ports"] + [f"{r['from']}-{r['to']}" for r in sc[f"allowed{proto.upper()}PortRanges"]]]
    stray = [o for o in opened if not any(not p["lan"] and p["port"] == o[2] and p["proto"] == o[1]
                                          and p["interface"] in (None, o[0]) for p in mine(host))]
    trusted = [i for i in fw["trustedInterfaces"] if i != "lo" and not any(p["port"] is None and p["interface"] == i for p in mine(host))]
    check(stray == [] and trusted == [], f"{host} opens and trusts only public entries ({opened}, {fw['trustedInterfaces']})")

toml = tomllib.loads((ROOT / "modules/homelab/llm-gateway.toml").read_text())["server"]
bound = dict(P["bound"], **{"gateway-api": toml["listen"].rsplit(":", 1)[1], "gateway-admin": toml["admin_listen"].rsplit(":", 1)[1]})
check(sorted(bound) == sorted(L) and all(int(bound[n]) == L[n]["port"] for n in L),
      f"every listener's service binds the listener's port ({ {n: (bound.get(n), L[n]['port']) for n in L} })")
OPENS = "firewall opens what sam.fleet does not list"
for seed, host, marker, what in [("openPort", "acer-swift", '"port":9999', "allowedTCPPorts = [ 9999 ] on acer"),
                                 ("upstreamOpen", "msi-ms7758", "--dport 9100", "the node exporter's upstream openFirewall on msi"),
                                 ("strayRule", "lenovo-21CB001PMX", "192.168.10.50", "a hand-written accept rule on lenovo"),
                                 ("trusted", "black-pi", "eth0", "trustedInterfaces = [ eth0 ] on black-pi"),
                                 ("lokiAnySource", "black-pi", f'"port":{ports["loki"]}', "Loki in black-pi's allowedTCPPorts"),
                                 ("ntfyElsewhere", "msi-ms7758", f'"port":{ports["ntfy"]}', "ntfy on msi, off its public entry's host")]:
    check(any(f"{host}'s {OPENS}" in m and marker in m for m in F[seed]), f"seeded: {what} fails ({F[seed]})")
check(any("sam.fleet.loki is served here" in m and "loopback" in m for m in F["lokiLoopback"]),
      f"seeded: black-pi's Loki on loopback fails ({F['lokiLoopback']})")
check(any("naked-pi has no address in sam.fleet.hosts" in m for m in F["collectorOffFleet"]),
      f"seeded: a collector on naked-pi, which has no fleet address, fails ({F['collectorOffFleet']})")

runtime = ["acer-swift", "asus-b460m", "msi-ms7758"]
check(sorted(P["machines"]) == runtime and sorted(P["jumpHosts"].values()) == runtime,
      f"lenovo's machines and jump hosts are the runtime hosts ({P['machines']}, {P['jumpHosts']})")
check(any("sam.herdr.machines targets acer-swift msi-ms7758, not the runtime hosts" in m for m in F["machineForgotten"]),
      f"seeded: a runtime host left out of sam.herdr.machines fails ({F['machineForgotten']})")
check(any("sam.workers.jumpHosts names" in m and "old-host" in m for m in F["jumpHostRemoved"]),
      f"seeded: a jump host hosts.nix does not have fails ({F['jumpHostRemoved']})")

# The table itself with asus-b460m removed: lenovo still lists it, so both of its assertions fail.
with tempfile.TemporaryDirectory() as tmp:
    for p in tracked:
        src = ROOT / p
        if src.is_file():
            (pathlib.Path(tmp) / p).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, pathlib.Path(tmp) / p)
    table = pathlib.Path(tmp) / "flake-modules/hosts.nix"
    lines = table.read_text().splitlines(keepends=True)
    kept = [l for l in lines if not l.lstrip().startswith("asus-b460m = ")]
    check(len(kept) == len(lines) - 1, "seeded: asus-b460m's entry is removed from the copied hosts.nix")
    table.write_text("".join(kept))
    expr = (f'let c = (builtins.getFlake "path:{tmp}").nixosConfigurations.lenovo.config; '
            'in map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions)')
    r = subprocess.run(["nix", "eval", "--impure", "--json", "--expr", expr], capture_output=True, text=True, check=False,
                       env=dict(os.environ))
    out = r.stdout + r.stderr
    check(r.returncode == 0 and "sam.herdr.machines targets acer-swift msi-ms7758 asus-b460m, not the runtime hosts" in out
          and "sam.workers.jumpHosts names" in out,
          f"seeded: asus-b460m removed from hosts.nix fails lenovo's machines and jump-host assertions ({out[-400:]!r})")

finish()
