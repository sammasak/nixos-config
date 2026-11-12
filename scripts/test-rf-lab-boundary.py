"""naked-pi's RF lab stays within its boundary (nixos-config#42 DoD): no heavyweight reverse-engineering
tooling on the 1 GiB Pi, no k3s there, and no rf-lab module on any other host (black-pi and the k3s nodes).

Evaluation only: the packages each host declares (system and Home Manager), never a build."""
import sys

import gate_probe

failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


r = gate_probe.section("rf-lab-boundary")
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
