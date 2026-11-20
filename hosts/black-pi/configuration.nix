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

  # Idle-exit overlap can inflate /proc/stat and invalidate capacity measurements (#601).
  boot.kernelPatches = [
    {
      name = "cpu-idle-overlap-96a494c9";
      patch = ../../pkgs/patches/linux-cpu-accounting/idle-overlap.patch;
    }
    {
      name = "cpu-idle-warning-b327e636";
      patch = ../../pkgs/patches/linux-cpu-accounting/idle-warning.patch;
    }
  ];
  assertions = [
    {
      assertion = config.boot.kernelPackages.kernel.version == "7.2.10";
      message = "black-pi: recheck/remove the CPU accounting backports when changing kernel 7.2.10 (#601).";
    }
  ];

  # Unauthenticated, per #302: the journal collectors and pi-offload push, Grafana here reads on loopback.
  # A fresh store; the chart's volume stays on disk.
  homelab.loki = {
    enable = true;
    listenAddress = config.sam.fleet.hosts.black-pi.address;
  };

  # to its own LAN address, which the kernel delivers on lo (always accepted), so sam.fleet.loki.from leaves it out
  homelab.journalCollector.enable = true;

  sam.profile = {
    username = "lukas";
    hostname = "black-pi";
    devTools = false;
  };
  sam.hostSecrets.enable = true;

  services.journald.settings.Journal.SystemMaxUse = lib.mkForce "200M";

  nix.settings = {
    # The 29 GB SD card also holds the observability volumes; min-free makes nix GC itself during builds.
    min-free = 3 * 1024 * 1024 * 1024;
    max-free = 8 * 1024 * 1024 * 1024;
    # nodejs/neovim/herdr build on the Pi (aarch64 cache misses); 4x4 threads OOM it.
    max-jobs = 1;
    cores = 2;
  };
}
