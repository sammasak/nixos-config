"""The runtime-host role (modules/roles/runtime-host.nix) on msi-ms7758 and acer-swift: a headless unthemed
default boot, and store maintenance that waits for a synchronised clock and never catches up at boot. acer's desktop specialisation keeps its theming.

Evaluation only: options and unit declarations, never a build."""
import json
import os
import subprocess
import sys

failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


EXPR = r"""
let
  f = builtins.getFlake (toString %(root)s);
  lib = f.inputs.nixpkgs.lib;
  facts = c: {
    roles = c.sam.profile.roles;
    hostSecrets = c.sam.hostSecrets.enable;
    deployUser = c.users.users ? deploy;
    stylix = c.stylix.enable;
    hmStylix = c.home-manager.users.${c.sam.profile.username} ? stylix;
    gui = c.services.displayManager.enable || c.services.xserver.enable;
    waitSync = lib.elem "systemd-time-wait-sync.service" c.systemd.additionalUpstreamSystemUnits
      && c.systemd.services.systemd-time-wait-sync.wantedBy == [ "sysinit.target" ];
    persistent = map (t: c.systemd.timers.${t}.timerConfig.Persistent) [ "nix-gc" "nix-optimise" ]
      ++ [ c.system.autoUpgrade.persistent ];
    upgradeHooks = with c.systemd.services.nixos-upgrade; onSuccess ++ onFailure;
    upgradeAfter = c.systemd.services.nixos-upgrade.after;
    optimiseAfter = c.systemd.services.nix-optimise.after;
  };
  failing = c: map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions);
  host = n: f.nixosConfigurations.${n};
  # the negative case: the role's own assertion must see a themed headless boot
  broken = modules: failing ((host "msi-ms7758").extendModules { inherit modules; }).config;
in {
  hosts = lib.genAttrs [ "msi-ms7758" "acer-swift" ] (n: facts (host n).config // { failing = failing (host n).config; });
  acerDesktop = facts (host "acer-swift").config.specialisation.desktop.configuration;
  themed = broken [ { stylix.enable = lib.mkOverride 0 true; } ];
}
"""

root = os.getcwd()
out = subprocess.run(["nix", "eval", "--impure", "--json", "--expr", EXPR % {"root": json.dumps(root)}],
                     capture_output=True, text=True)
if out.returncode != 0:
    print("FAIL: evaluating the runtime hosts: " + out.stderr.strip()[-1200:])
    sys.exit(1)
r = json.loads(out.stdout)

for name, h in sorted(r["hosts"].items()):
    check("runtime-host" in h["roles"] and "base" in h["roles"], f"{name} carries the runtime-host role")
    check(h["failing"] == [], f"{name}: no failing assertion {h['failing']}")
    check(h["hostSecrets"] and h["deployUser"], f"{name} has the workers' credential (hostSecrets) and the deploy-rs login")
    check(not h["stylix"] and not h["hmStylix"] and not h["gui"],
          f"{name} boots headless: no Stylix (NixOS or Home Manager), no display manager, no X server")
    check(h["waitSync"], f"{name}: time-sync.target waits for a synchronised clock (systemd-time-wait-sync)")
    check(h["persistent"] == [False, False, False],
          f"{name}: nix-gc, nix-optimise and nixos-upgrade do not catch up at boot ({h['persistent']})")
    check(h["upgradeHooks"] == [], f"{name}: nixos-upgrade has no desktop-notification hook {h['upgradeHooks']}")
    check("nix-gc.service" in h["optimiseAfter"] and {"nix-gc.service", "nix-optimise.service"} <= set(h["upgradeAfter"]),
          f"{name}: optimise waits for GC, the upgrade for both")

d = r["acerDesktop"]
check(d["stylix"] and d["hmStylix"] and d["gui"], "acer's desktop specialisation keeps Stylix and its display manager")
check(len(d["upgradeHooks"]) == 2, f"acer's desktop specialisation keeps the upgrade notifications {d['upgradeHooks']}")
check(d["persistent"] == [False, False, False] and d["waitSync"], "acer's desktop specialisation keeps the maintenance policy")

check(any("default boot is headless" in m for m in r["themed"]), f"negative case themed: the role's assertion fails ({len(r['themed'])} failing)")
sys.exit(1 if failed else 0)
