{ pkgs, ... }:
let
  vars = import ./variables.nix;
in
{
  imports = [
    ./hardware-configuration.nix
    (import ../../modules/hardware/disko-single-ext4.nix "/dev/disk/by-id/nvme-INTEL_SSDPEKNW010T8_BTNH014425J11P0B")

    ../../modules/hardware/video/intel.nix
  ];

  sam.profile = vars;
  # k3s pods take ~4.6G here: a 7G pool reserves 2G each for at most 3, 2 recommended (docs/nspawn-workers.md, Sizing).
  sam.workers = {
    retired = [ "docs" "ghp" "demo" "dp93" "nc200" "dp120" "f44" "dp121" "boot2" "boot" "push" "pin" "note" "evfix" "pins" "tel1" "fac" "evdoc" "sk" "w1" "tg" "tel2" "tg2" ];
    labelPrefix = "acer";
    pool.memory = "7G";
    ghHostsFile = "/home/${vars.username}/.config/gh/hosts.yml";
  };
  # The relay and environments' telemetry only: host sessions here keep their Claude settings (docs/native-otel-canary.md)
  sam.claude.telemetry.enable = false;
  sam.herdr.trustedDirs = map (d: "/home/${vars.username}/${d}") [ "claude-code-skills" "knowledge" "nixos-config" ".cache/wt" ];

  # Headless shell mode remains the default for the always-on worker. The GUI
  # variant is an explicit boot-menu specialisation for daily laptop use.
  specialisation.desktop.configuration = {
    imports = [ ../../modules/specialisations/desktop.nix ];
  };

  # The only host that upgrades unattended. allowReboot is pinned to false: as
  # sole worker an unattended reboot is a total cluster outage (the reserved
  # taint strands DNS, kyverno and ntfy, so paging dies with it). The reboot is
  # operator-initiated. A shared module that sets true fails the evaluation.
  system.autoUpgrade.enable = true;
  system.autoUpgrade.allowReboot = false;

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
