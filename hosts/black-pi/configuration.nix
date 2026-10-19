{ lib, ... }:
let
  vars = import ./variables.nix;
in
{
  imports = [
    ./hardware-configuration.nix

    # Registers crun as an additional containerd runtime for k3s (worker parity).
    ../../modules/homelab/k3s/containerd-crun.nix

    # Directly, not via the laptop role (Intel-only settings). No wifi-selfheal:
    # wlan0 is the secondary NIC here, end0 carries the cluster.
    ../../modules/core/wifi.nix

    ../../modules/hardware/sd-image-root-lock.nix
  ];

  sam.profile = vars;
  sam.hostSecrets.enable = true;
  sam.wifi.declarativeHomeProfile = true;

  # mkForce: the fleet's monthly 30-day GC can fill this 29 GB SD card, which also
  # holds the observability volumes; min-free makes nix GC itself during builds.
  nix.gc.dates = lib.mkForce "weekly";
  nix.gc.options = lib.mkForce "--delete-older-than 7d";
  nix.settings.min-free = 3 * 1024 * 1024 * 1024;
  nix.settings.max-free = 8 * 1024 * 1024 * 1024;
  services.journald.settings.Journal.SystemMaxUse = lib.mkForce "200M";

  # No UEFI: the Pi firmware chains U-Boot, which reads /boot/extlinux.
  # https://wiki.nixos.org/wiki/NixOS_on_ARM/Raspberry_Pi_4
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;


  # nodejs/neovim/herdr build on the Pi (aarch64 cache misses); 4x4 threads OOM it.
  nix.settings = {
    max-jobs = 1;
    cores = 2;
  };

  # Weekly upgrades would compile nodejs on the SD card; revisit when aarch64 caches it.
  system.autoUpgrade.enable = lib.mkForce false;

  homelab.k3s.serverAddr = "https://192.168.10.154:6443"; # k3s server on lenovo-21CB001PMX
  homelab.k3s.cni = "cilium"; # must match control-plane: Cilium KPR, kube-proxy disabled
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
