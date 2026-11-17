#!/usr/bin/env python3
"""The fleet's ntfy and Loki ports and its host list, held to their definitions: no tracked file but
modules/core/fleet.nix names either port (one allowlisted line, with its reason), ntfy or Loki on a port off its
sam.fleet fact fails an assertion, black-pi's Loki admits exactly the other fleet hosts' addresses, and lenovo's
sam.herdr.machines and jump hosts must be the runtime hosts of flake-modules/hosts.nix: one left out, one the table no
longer has, and the table with asus-b460m removed each fail evaluation; a collector on a host without a fleet address
fails too."""
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

import gate_probe

ROOT = pathlib.Path(__file__).resolve().parent.parent
failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


P = gate_probe.section("fleet-contract")
ports = P["ports"]
check(sorted(ports) == ["loki", "ntfy"] and all(isinstance(p, int) for p in ports.values()), f"the fleet's ports are read {ports}")

# (path, port name) -> why the literal may stay
ALLOWED = {
    ("scripts/platform-record.sh", "loki"):
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
                if (path, name) in ALLOWED:
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
for (path, name), why in ALLOWED.items():
    text = dict(files).get(path, "")
    check(re.search(rf"(?<![0-9]){ports[name]}(?![0-9])", text) is not None, f"allowlisted {path} still names the {name} port ({why})")
seeded = literals(files + [("modules/homelab/x.nix", f'  listen = ":{ports["ntfy"]}";')])
check([(p, k) for p, _, k, _ in seeded] == [("modules/homelab/x.nix", "ntfy")],
      f"seeded: a module naming the ntfy port as a literal is found ({seeded})")

F = P["failing"]
check(F["lenovo"] == [] and F["blackPi"] == [], f"lenovo and black-pi pass their assertions ({F['lenovo']}, {F['blackPi']})")
check(any("homelab.ntfy.port 2587 is not sam.fleet.ntfy.port" in m for m in F["ntfyPort"]),
      f"seeded: homelab.ntfy.port = 2587 on lenovo fails ({F['ntfyPort']})")
check(any("homelab.loki.port 3101 is not sam.fleet.loki.port" in m for m in F["lokiPort"]),
      f"seeded: homelab.loki.port = 3101 on black-pi fails ({F['lokiPort']})")

others = sorted(a for h, addrs in P["addresses"].items() if h != "black-pi" for a in addrs)
check(sorted(P["allowedSources"]) == others and len(set(P["allowedSources"])) == len(others),
      f"black-pi's Loki admits each other fleet host's addresses once ({P['allowedSources']})")
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

sys.exit(1 if failed else 0)
