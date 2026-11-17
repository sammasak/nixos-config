{ config, lib, ... }:
{
  imports = [
    ./hardware-configuration.nix

    # Directly, not via the laptop role (Intel-only settings). No wifi-selfheal:
    # wlan0 is the secondary NIC here, end0 carries the LAN.
    ../../modules/core/wifi.nix

    ../../modules/hardware/pi-sd-image.nix

    # The fleet's monitoring (nixos-config#414); alloy-otlp, its OTLP intake, runs on acer.
    ../../modules/homelab/monitoring/prometheus.nix
    ../../modules/homelab/monitoring/alertmanager.nix
    ../../modules/homelab/monitoring/grafana.nix
    ../../modules/homelab/monitoring/node-exporter.nix
    ../../modules/homelab/loki.nix
    ../../modules/homelab/journal-collector.nix
  ];

  # Unauthenticated, per #302: the journal collectors and pi-offload push, Grafana here reads on loopback.
  # A fresh store; the chart's volume stays on disk.
  homelab.loki = {
    enable = true;
    listenAddress = config.sam.fleet.hosts.black-pi.address;
    allowedSources = lib.concatMap (h: [ h.address ] ++ h.extraAddresses) (
      lib.attrValues (removeAttrs config.sam.fleet.hosts [ config.networking.hostName ])
    );
  };

  # to its own LAN address, which the kernel delivers on lo (always accepted), so it needs no allowedSources entry
  homelab.journalCollector.enable = true;

  sam.profile = {
    username = "lukas";
    hostname = "black-pi";
    devTools = false;
  };
  sam.hostSecrets.enable = true;

  # The 29 GB SD card also holds the observability volumes; min-free makes nix GC itself during builds.
  nix.settings.min-free = 3 * 1024 * 1024 * 1024;
  nix.settings.max-free = 8 * 1024 * 1024 * 1024;
  services.journald.settings.Journal.SystemMaxUse = lib.mkForce "200M";

  # nodejs/neovim/herdr build on the Pi (aarch64 cache misses); 4x4 threads OOM it.
  nix.settings = {
    max-jobs = 1;
    cores = 2;
  };
}
