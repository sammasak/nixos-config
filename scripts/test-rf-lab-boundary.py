"""naked-pi's RF lab stays on naked-pi (nixos-config#42 DoD): no rf-lab module or rf-* unit on any other host
(black-pi and the k3s nodes). That naked-pi itself carries no heavyweight reverse-engineering tooling and no
k3s is an assertion of modules/roles/rf-lab.nix, so every evaluation of naked-pi enforces it.

Evaluation only, never a build."""
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
check(pi is not None and pi["rfLabEnabled"], "naked-pi runs the rf-lab role (whose assertions bound it)")
others = {h: f for h, f in hosts.items() if h != "naked-pi"}
check("black-pi" in others, "black-pi is evaluated")
for h, f in sorted(others.items()):
    check(not f["rfLab"] and f["rfUnits"] == [],
          f"{h}{' (k3s)' if f['k3s'] else ''}: no rf-lab module and no rf-* unit {f['rfUnits']}")
sys.exit(1 if failed else 0)
