# Host configuration for acer-swift
{ lib, pkgs, ... }:
let
  vars = import ./variables.nix;
in
{
  imports = [
    ./hardware-configuration.nix

    # Hardware
    ../../modules/hardware/video/${vars.videoDriver}.nix

    # Register crun as additional containerd runtime for k3s
    ../../modules/homelab/k3s/containerd-crun.nix
  ];

  sam.profile = vars;
  sam.secrets.enable = true;

  # Headless (server) mode is the ONLY boot mode — acer-swift is a k3s worker
  # and runs without a GUI.
  # Removed 2026-08-27: the `desktop` specialisation (never booted since it was
  # added on 2026-08-16, ~5 GiB of closure). To restore, re-add:
  #   specialisation.desktop.configuration.imports = [ ../../modules/specialisations/desktop.nix ];

  # Never let the Sunday 03:00 auto-upgrade reboot this box on its own.
  # acer-swift is the sole k3s worker: an unattended reboot is a total cluster
  # outage (the reserved taint strands every singleton — DNS, kyverno, ntfy —
  # so paging is impossible while it is down). Upgrades may still build and
  # activate; the reboot is operator-initiated, at a time someone is watching.
  # See the 2026-08-26 OOM incident.
  system.autoUpgrade.allowReboot = lib.mkForce false;

  # k3s agent configuration
  homelab.k3s.serverAddr = "https://192.168.10.154:6443";  # k3s server on lenovo-21CB001PMX
  homelab.k3s.cni = "cilium";  # match control-plane: disable kube-proxy for Cilium KPR
  homelab.k3s.extraFlags = [
    "--node-label=node-pool=workers"
  ];

  # Acer laptop: use generic thermal policy (BIOS/EC fan tables + thermald).
  # Turbo boost disabled: keeps idle package temp ~10-15°C lower (below the 63°C fan trigger).
  # EPP balance_power: biases HWP toward lower voltage/frequency at idle.
  sam.thermal = {
    enable = true;
    platform = "generic";
    profile = "balanced";
    disableTurboBoost = true;
    energyPerformancePreference = "balance_power";
  };

  # Disable WiFi power management to prevent brief link flaps.
  # iwlwifi power_save + NetworkManager defaults allow the NIC to enter deep
  # power states, causing ~300-500 ms drops that break k3s virt-handler API
  # watches ("no route to host" on 10.43.0.1:443, clean Exit Code 0).
  # acer-swift sees ~3.3 virt-handler restarts/day vs msi-ms7758's ~0.16/day,
  # consistent with a laptop-specific WiFi instability (msi-ms7758 is wired).
  # See: TICKET-2026-06-06-infra-043.
  networking.networkmanager.wifi.powersave = false;
  # d0i3_disable was dropped from iwlwifi upstream (~kernel 6.19); passing it is
  # silently inert, so only power_save=0 remains.
  boot.extraModprobeConfig = ''
    options iwlwifi power_save=0
  '';

  # WiFi self-heal for a HEADLESS sole-worker node.
  # Root cause of the 2026-08-02 → 08-12 total-cluster outage (oncall-082): the AP
  # deauthed mid-4-way-handshake (Reason 2 PREV_AUTH_NOT_VALID); wpa_supplicant
  # mis-flagged it WRONG_KEY; after NetworkManager's default 4 autoconnect retries
  # it gave up and requested the secret from an *agent* — which never exists on a
  # headless server ("no secrets: No agents were available") — so a transient blip
  # became a 10-day outage. Two layers prevent recurrence:
  #
  # 1. Never stop retrying autoconnect (default is 4). With infinite retries NM keeps
  #    re-attempting with the stored system secret (no agent needed) and reconnects
  #    on its own once the AP recovers.
  networking.networkmanager.settings.connection."connection.autoconnect-retries" = 0;

  # 2. Defense-in-depth watchdog: if the LAN gateway is unreachable for one interval
  #    (NM itself wedged, driver stuck, etc.), bounce the WiFi device and, failing
  #    that, restart NetworkManager. Cheap ping; only acts when connectivity is lost.
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
