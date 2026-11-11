{ lib, pkgs, ... }:
let
  vars = import ./variables.nix;
in
{
  imports = [
    ./hardware-configuration.nix
    (import ../../modules/hardware/disko-single-ext4.nix "/dev/disk/by-id/nvme-INTEL_SSDPEKNW010T8_BTNH014425J11P0B")

    ../../modules/hardware/video/${vars.videoDriver}.nix
  ];

  sam.profile = vars;
  # k3s pods take ~4.6G here: a 7G pool reserves 2G each for at most 3, 2 recommended (docs/nspawn-workers.md, Sizing).
  sam.workers = {
    instances = {
      f44 = {
        model = "sonnet";
        prompt = "You are in a fresh nspawn developer environment named f44 on host acer-swift. Task: factum issue #44 (approved). Clone git@github.com:sammasak/factum.git into ~/factum, read its entry doc (CLAUDE.md if present, else README or CONTRIBUTING), and run gh issue view 44. Check for an existing branch or open PR for the issue first; if one exists take it to mergeable instead of starting over. Follow the issue's own scope and gates exactly; where it says a decision is the owner's, stop there and report. Run gates and heavy commands one at a time. Before pushing, spawn ONE independent subagent to review your diff, fix what is real, push, open the PR with gh, and finish with a five line summary. Append any friction with this environment to ~/ENV-FEEDBACK.md. Stop and ask if a decision is not yours.";
      };
      dp121 = {
        model = "sonnet";
        prompt = "You are in a fresh nspawn developer environment named dp121 on host acer-swift (deployed from the coordinator's branch, so main may not declare it yet). Task: devenv-platform issue #121 (approved): gates G0 and G1 only, then stop at owner gate D1. Clone git@github.com:sammasak/devenv-platform.git into ~/devenv-platform, run devenv shell once so the git hooks are installed (commits need a Why: line), read the README's first section, and read the issue with gh issue view 121 --json body,comments. Check the issue's links and file references against HEAD before relying on them, and check for an existing branch, PR or RFC comment for the issue first; continue from it instead of starting over. Follow the issue's binding instructions exactly: baseline A with existing commands only, B and C on paper only, no plugin installs, no host changes. This environment shares the host Nix store through the host daemon (2 build jobs, 2 cores each, shared with other environments), so a path is cold only once: say which runs were truly cold and mark what you could not measure UNTESTED. Run builds strictly one at a time with output sent to a log file. Before posting, spawn ONE independent subagent to check your tables against the raw logs and fix what is real. Then post the one RFC comment the issue asks for on #121 (no em dashes), propose but do not choose D1, and finish with a five line summary. Append friction with this environment to ~/ENV-FEEDBACK.md.";
      };
    };
    retired = [ "demo" "dp93" "nc200" "dp120" ];
    labelPrefix = "acer";
    pool = { memory = "7G"; cores = 8; };
    ghHostsFile = "/home/${vars.username}/.config/gh/hosts.yml";
  };
  # An environment's builds run in this daemon, outside the pool: bounded like lenovo's (a cores-2 build peaked at
  # 6.1G), past MemoryHigh it reclaims and swaps, past MemoryMax the build fails, never k3s or the host.
  nix.settings = { max-jobs = 2; cores = 2; };
  systemd.services.nix-daemon.serviceConfig = { MemoryHigh = "4G"; MemoryMax = "6G"; };
  sam.herdr.trustedDirs = map (d: "/home/${vars.username}/${d}") [ "claude-code-skills" "knowledge" "nixos-config" ".cache/wt" ];

  # Headless shell mode remains the default for the always-on worker. The GUI
  # variant is an explicit boot-menu specialisation for daily laptop use.
  specialisation.desktop.configuration = {
    imports = [ ../../modules/specialisations/desktop.nix ];
  };

  # Sole worker — an unattended reboot is a total cluster outage (the reserved
  # taint strands DNS, kyverno and ntfy, so paging dies with it). Upgrades still
  # build and activate; the reboot is operator-initiated.
  system.autoUpgrade.allowReboot = lib.mkForce false;

  homelab.k3s.serverAddr = "https://192.168.10.154:6443";  # k3s server on lenovo-21CB001PMX
  homelab.k3s.cni = "cilium";  # match control-plane: disable kube-proxy for Cilium KPR
  homelab.k3s.extraFlags = [
    "--node-label=node-pool=workers"
  ];

  # Keep turbo available for interactive coding and builds. Power-profiles-daemon
  # still provides the battery-aware system profile; EPP keeps sustained work
  # balanced instead of forcing the server-oriented power bias.
  sam.thermal = {
    enable = true;
    platform = "generic";
    profile = "balanced";
    disableTurboBoost = false;
    energyPerformancePreference = "balance_performance";
  };

  # WiFi powersave lets the NIC enter deep states, causing ~300-500 ms link
  # drops that break k3s API watches.
  # See vault: homelab/acer-swift-wifi-resilience.md
  networking.networkmanager.wifi.powersave = false;
  boot.extraModprobeConfig = ''
    options iwlwifi power_save=0
  '';

  # Defence in depth for what the retry loop cannot reach: NetworkManager
  # wedged, driver stuck, associated but carrying no traffic.
  systemd.services.wifi-selfheal = {
    description = "Reconnect WiFi when the LAN gateway is unreachable (headless self-heal)";
    after = [ "NetworkManager.service" ];
    serviceConfig.Type = "oneshot";
    path = [ pkgs.iputils pkgs.networkmanager pkgs.util-linux ];
    script = ''
      if ! ping -c3 -W2 192.168.10.1 >/dev/null 2>&1; then
        logger -t wifi-selfheal "LAN gateway 192.168.10.1 unreachable — bouncing wlp0s20f3"
        nmcli device disconnect wlp0s20f3 || true
        sleep 2
        nmcli device connect wlp0s20f3 || systemctl restart NetworkManager.service
      fi
    '';
  };
  systemd.timers.wifi-selfheal = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "3min";
    };
  };

}
