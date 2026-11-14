{ config, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    (import ../../modules/hardware/disko-single-ext4.nix "/dev/disk/by-id/nvme-INTEL_SSDPEKNW010T8_BTNH014425J11P0B")

    ../../modules/hardware/video/intel.nix
  ];

  sam.profile = {
    username = "lukas";
    hostname = "acer-swift";
    # herdr host: Pi run viewer panes run pi-view here (devenv-platform#28).
    pi = true;
    nativeOtel = true;
  };
  # k3s pods take ~4.6G here: a 7G pool reserves 2G each for at most 3, 2 recommended (docs/nspawn-workers.md, Sizing).
  sam.workers = {
    retired = [ "docs" "ghp" "demo" "dp93" "nc200" "dp120" "f44" "dp121" "boot2" "boot" "push" "pin" "note" "evfix" "pins" "tel1" "fac" "evdoc" "sk" "w1" "tg" "tel2" "tg2" ];
    labelPrefix = "acer";
    pool.memory = "7G";
    ghHostsFile = "/home/${config.sam.profile.username}/.config/gh/hosts.yml";
    # No prompt: its goal is sent through Herdr once it is up (docs/nspawn-workers.md).
    instances.herman = { model = "claude-fable-5-2"; };
  };
  # The relay and environments' telemetry only: host sessions here keep their Claude settings (docs/native-otel-canary.md)
  sam.claude.telemetry.enable = false;
  sam.cliTools.nixAudit.enable = true;
  sam.herdr.trustedDirs = map (d: "/home/${config.sam.profile.username}/${d}") [ "claude-code-skills" "knowledge" "nixos-config" ".cache/wt" ];

  # Headless shell mode remains the default for the always-on worker. The GUI
  # variant is an explicit boot-menu specialisation for daily laptop use.
  specialisation.desktop.configuration = {
    imports = [ ../../modules/specialisations/desktop.nix ];
  };

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
    enableStrictShellChecks = true;
    script = ''
      if ! ping -c3 -W2 ${config.sam.fleet.gateway} >/dev/null 2>&1; then
        logger -t wifi-selfheal "LAN gateway ${config.sam.fleet.gateway} unreachable — bouncing wlp0s20f3"
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
