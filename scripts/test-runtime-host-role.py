"""The runtime-host role (modules/roles/runtime-host.nix) on msi-ms7758 and acer-swift: a headless unthemed
default boot, no unattended upgrade from main (modules/core/automation.nix asserts it off on every host), and store
maintenance that waits for a synchronised clock and never catches up at boot. acer's desktop specialisation keeps its theming.

Evaluation only: options and unit declarations, never a build."""
import sys

import gate_probe

failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


r = gate_probe.section("runtime-host")

for name, h in sorted(r["hosts"].items()):
    check("runtime-host" in h["roles"] and "base" in h["roles"], f"{name} carries the runtime-host role")
    check(h["failing"] == [], f"{name}: no failing assertion {h['failing']}")
    check(h["hostSecrets"] and h["deployUser"], f"{name} has the workers' credential (hostSecrets) and the deploy-rs login")
    check(not h["stylix"] and not h["hmStylix"] and not h["gui"],
          f"{name} boots headless: no Stylix (NixOS or Home Manager), no display manager, no X server")
    check(h["waitSync"], f"{name}: time-sync.target waits for a synchronised clock (systemd-time-wait-sync)")
    check(h["persistent"] == [False, False],
          f"{name}: nix-gc and nix-optimise do not catch up at boot ({h['persistent']})")
    check(h["autoUpgrade"] is False, f"{name}: no unattended upgrade from main; deploys go through deploy-rs")
    check("nix-gc.service" in h["optimiseAfter"], f"{name}: optimise waits for GC")

d = r["acerDesktop"]
check(d["stylix"] and d["hmStylix"] and d["gui"], "acer's desktop specialisation keeps Stylix and its display manager")
check(d["persistent"] == [False, False] and d["waitSync"], "acer's desktop specialisation keeps the maintenance policy")
check(d["autoUpgrade"] is False, "acer's desktop specialisation does not upgrade unattended either")

sys.exit(1 if failed else 0)
