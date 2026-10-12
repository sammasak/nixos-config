{ lib, ... }:
let
  vars = import ./variables.nix;
in
{
  imports = [ ./hardware-configuration.nix ];

  sam.profile = vars;

  # No UEFI: the Pi firmware chains U-Boot, which reads /boot/extlinux.
  # https://wiki.nixos.org/wiki/NixOS_on_ARM/Raspberry_Pi_4
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

  # The SD image creates root with an empty password; mutableUsers would keep it.
  users.users.root.hashedPassword = "!";

  # Manual until the first SD-card boot of this config is verified.
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

  # Held off until that first boot is verified; the homelab-agent role turns it on.
  homelab.k3s.enable = lib.mkForce false;
}
