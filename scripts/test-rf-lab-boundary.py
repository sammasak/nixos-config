"""naked-pi's RF lab stays within its boundary (nixos-config#42 DoD): no heavyweight reverse-engineering
tooling on the 1 GiB Pi, no k3s there, and no rf-lab module on any other host (black-pi and the k3s nodes).

Evaluation only: the packages each host declares (system and Home Manager), never a build."""
import json
import os
import subprocess
import sys

failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


# REA and the tools it drives belong on the analysis workstation (#42 "Architectural boundaries")
HEAVY = r".*(ghidra|binwalk|unblob|jadx|nodejs|npm|rea-agents|radare2|rizin).*"

EXPR = r"""
let
  f = builtins.getFlake (toString %(root)s);
  heavy = %(heavy)s;
  names = ps: map (p: p.pname or p.name or "?") ps;
  declared = c: names c.environment.systemPackages
    ++ builtins.concatMap (u: names c.home-manager.users.${u}.home.packages) (builtins.attrNames c.home-manager.users);
  facts = c: {
    rfLab = (c.sam or { }) ? rfLab;
    rfLabEnabled = c.sam.rfLab.enable or false;
    k3s = c.services.k3s.enable;
    rfUnits = builtins.filter (s: builtins.match "rf-.*" s != null) (builtins.attrNames c.systemd.services);
    heavy = builtins.filter (n: builtins.match heavy (f.inputs.nixpkgs.lib.toLower n) != null) (declared c);
  };
  pi = f.nixosConfigurations.naked-pi;
  # the negative case: the same check must see a heavy tool added to naked-pi
  seeded = (pi.extendModules {
    modules = [ ({ pkgs, ... }: { environment.systemPackages = [ pkgs.binwalk pkgs.nodejs ]; }) ];
  }).config;
in {
  hosts = builtins.mapAttrs (_: h: facts h.config) f.nixosConfigurations;
  seeded = (facts seeded).heavy;
}
"""

root = os.getcwd()
out = subprocess.run(
    ["nix", "eval", "--impure", "--json", "--expr", EXPR % {"root": json.dumps(root), "heavy": json.dumps(HEAVY)}],
    capture_output=True, text=True)
if out.returncode != 0:
    print("FAIL: evaluating the hosts: " + out.stderr.strip()[-600:])
    sys.exit(1)
r = json.loads(out.stdout)
hosts = r["hosts"]

pi = hosts.get("naked-pi")
check(pi is not None and pi["rfLabEnabled"], "naked-pi runs the rf-lab role")
check(pi is not None and pi["heavy"] == [],
      f"naked-pi declares no heavyweight RE tooling (Ghidra, Binwalk, Unblob, JADX, REA, Node) {pi and pi['heavy']}")
check(pi is not None and not pi["k3s"], "naked-pi is not a k3s node")
others = {h: f for h, f in hosts.items() if h != "naked-pi"}
check("black-pi" in others, "black-pi is evaluated")
for h, f in sorted(others.items()):
    check(not f["rfLab"] and f["rfUnits"] == [],
          f"{h}{' (k3s)' if f['k3s'] else ''}: no rf-lab module and no rf-* unit {f['rfUnits']}")
check(sorted(r["seeded"]) == ["binwalk", "nodejs"],
      f"negative case: binwalk and nodejs added to naked-pi are both caught ({r['seeded']})")
sys.exit(1 if failed else 0)
