{ lib, ... }:
{
  imports = [
    ./hardware-configuration.nix

    # Directly, not via the laptop role (Intel-only settings). No wifi-selfheal:
    # wlan0 is the secondary NIC here, end0 carries the cluster.
    ../../modules/core/wifi.nix

    ../../modules/hardware/pi-sd-image.nix
  ];

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

  homelab.k3s.extraFlags = [
    "--node-label=node-pool=arm64"
    # Opt-in: most workloads are unpinned and many homelab images are amd64-only.
    "--node-taint=sammasak.dev/arch=arm64:NoSchedule"
  ];

  # The 15Gi-node defaults would reserve ~1.5Gi of 3.7Gi before a pod schedules.
  homelab.k3s.memory = {
    systemReserved = "512Mi";
    evictionHard = "200Mi";
    evictionSoft = "400Mi";
  };
}
