{ lib, pkgs, ... }:
let
  vars = import ./variables.nix;
in
{
  imports = [
    ./hardware-configuration.nix

    ../../modules/hardware/video/${vars.videoDriver}.nix

    # Registers crun as an additional containerd runtime for k3s.
    ../../modules/homelab/k3s/containerd-crun.nix
  ];

  sam.profile = vars;
  sam.secrets.enable = true;

  # Headless is the only boot mode: this is a k3s worker with no GUI.

  # Sole worker — an unattended reboot is a total cluster outage (the reserved
  # taint strands DNS, kyverno and ntfy, so paging dies with it). Upgrades still
  # build and activate; the reboot is operator-initiated.
  system.autoUpgrade.allowReboot = lib.mkForce false;

  homelab.k3s.serverAddr = "https://192.168.10.154:6443";  # k3s server on lenovo-21CB001PMX
  homelab.k3s.cni = "cilium";  # match control-plane: disable kube-proxy for Cilium KPR
  homelab.k3s.extraFlags = [
    "--node-label=node-pool=workers"
  ];

  # Turbo boost off keeps idle package temp ~10-15°C lower, below the 63°C fan
  # trigger; balance_power biases HWP toward lower voltage at idle.
  sam.thermal = {
    enable = true;
    platform = "generic";
    profile = "balanced";
    disableTurboBoost = true;
    energyPerformancePreference = "balance_power";
  };

  # WiFi powersave lets the NIC enter deep states, causing ~300-500 ms link
  # drops that break k3s API watches.
  # See vault: homelab/acer-swift-wifi-resilience.md
  networking.networkmanager.wifi.powersave = false;
  boot.extraModprobeConfig = ''
    options iwlwifi power_save=0
  '';

  # 0 = retry autoconnect forever using the stored system secret. The default of
  # 4 ends in a secret request to an *agent*, which never exists on a headless
  # box — that turned one AP deauth into a 10-day outage.
  networking.networkmanager.settings.connection."connection.autoconnect-retries" = 0;

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
