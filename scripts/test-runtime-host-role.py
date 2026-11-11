"""The runtime-host role (modules/roles/runtime-host.nix) on msi-ms7758 and acer-swift: the shared agent-runtime
host policy, a headless unthemed default boot, and store maintenance that waits for a synchronised clock and
never catches up at boot. acer's desktop specialisation keeps its theming.

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
    runtime = { inherit (c.sam.agentRuntime.host) enable eligibleTemplates maxConcurrentInstances reserve; };
    coderAllow = c.sam.agentRuntime.templates.claude-coder.network.allow;
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
    # a clock that never synchronises may hold calendar timers, never a service (acer's NTP comes over wifi)
    heldByClock = lib.attrNames (lib.filterAttrs
      (_: s: s.enable && lib.elem "time-sync.target" (s.after ++ s.requires ++ s.wants)) c.systemd.services);
  };
  failing = c: map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions);
  host = n: f.nixosConfigurations.${n};
  # the negative cases: the role's own assertions must see a themed headless boot and a runtime switched off
  broken = modules: failing ((host "msi-ms7758").extendModules { inherit modules; }).config;
in {
  hosts = lib.genAttrs [ "msi-ms7758" "acer-swift" ] (n: facts (host n).config // { failing = failing (host n).config; });
  acerDesktop = facts (host "acer-swift").config.specialisation.desktop.configuration;
  themed = broken [ { stylix.enable = lib.mkOverride 0 true; } ];
  off = broken [ { sam.agentRuntime.host = { enable = lib.mkForce false; eligibleTemplates = lib.mkForce [ ]; }; } ];
  # black-pi declares no capacity of its own: the role on it must not fall back to the module defaults
  defaultCapacity = failing ((host "black-pi").extendModules { modules = [ "${f}/modules/roles/runtime-host.nix" ]; }).config;
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
    check(h["runtime"]["enable"] and h["runtime"]["eligibleTemplates"] == ["rust-pilot", "claude-coder"],
          f"{name} admits the role's templates ({h['runtime']['eligibleTemplates']})")
    check(h["coderAllow"] == ["api.anthropic.com"], f"{name}: the coder template's only egress is the Claude API host")
    check(h["hostSecrets"] and h["deployUser"], f"{name} has the run credential (hostSecrets) and the deploy-rs login")
    check(not h["stylix"] and not h["hmStylix"] and not h["gui"],
          f"{name} boots headless: no Stylix (NixOS or Home Manager), no display manager, no X server")
    check(h["waitSync"], f"{name}: time-sync.target waits for a synchronised clock (systemd-time-wait-sync)")
    check(h["persistent"] == [False, False, False],
          f"{name}: nix-gc, nix-optimise and nixos-upgrade do not catch up at boot ({h['persistent']})")
    check(h["upgradeHooks"] == [], f"{name}: nixos-upgrade has no desktop-notification hook {h['upgradeHooks']}")
    check(h["heldByClock"] == [], f"{name}: no service waits for time-sync.target {h['heldByClock']}")
    check("nix-gc.service" in h["optimiseAfter"] and {"nix-gc.service", "nix-optimise.service"} <= set(h["upgradeAfter"]),
          f"{name}: optimise waits for GC, the upgrade for both")

msi, acer = r["hosts"]["msi-ms7758"]["runtime"], r["hosts"]["acer-swift"]["runtime"]
check(msi["maxConcurrentInstances"] == 2 and msi["reserve"] == {"cpus": 2, "memoryMiB": 8192, "diskMiB": 51200},
      f"msi keeps its own capacity ({msi['maxConcurrentInstances']}, {msi['reserve']})")
check(acer["maxConcurrentInstances"] == 1 and acer["reserve"] == {"cpus": 0, "memoryMiB": 4096, "diskMiB": 51200},
      f"acer keeps its own capacity ({acer['maxConcurrentInstances']}, {acer['reserve']})")

d = r["acerDesktop"]
check(d["stylix"] and d["hmStylix"] and d["gui"], "acer's desktop specialisation keeps Stylix and its display manager")
check(len(d["upgradeHooks"]) == 2, f"acer's desktop specialisation keeps the upgrade notifications {d['upgradeHooks']}")
check(d["persistent"] == [False, False, False] and d["waitSync"], "acer's desktop specialisation keeps the maintenance policy")

for case, text in (("themed", "default boot is headless"), ("off", "must stay on"), ("defaultCapacity", "own measurement")):
    check(any(text in m for m in r[case]), f"negative case {case}: the role's assertion fails ({len(r[case])} failing)")
sys.exit(1 if failed else 0)
