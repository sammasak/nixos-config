{ lib, pkgs, ... }:
let
  vars = import ./variables.nix;
in
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/hardware/video/${vars.videoDriver}.nix
    # Registers crun as an additional containerd runtime for k3s (worker parity).
    ../../modules/homelab/k3s/containerd-crun.nix
    # Scheduled work-hours power window (self-shutdown half; lenovo does the wake).
    ../../modules/homelab/msi-power-schedule.nix
  ];

  # Powered on Mon-Fri ~09:00 (WoL from lenovo) and gracefully shut down at 21:00.
  homelab.msiPowerSchedule.selfShutdown.enable = true;

  sam.profile = vars;

  # Keep this host manual until the existing Windows/EFI layout is verified.
  system.autoUpgrade.enable = lib.mkForce false;
  system.autoUpgrade.allowReboot = lib.mkForce false;

  # The existing Windows ESP is small. Keep GRUB's mutable directory on root,
  # while leaving only the EFI loader on /boot.
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.grub = {
    enable = true;
    device = "nodev";
    efiSupport = true;
    useOSProber = false;
    configurationLimit = 5;
    mirroredBoots = lib.mkForce [
      {
        path = "/boot-nix";
        efiSysMountPoint = "/boot";
        devices = [ "nodev" ];
      }
    ];
    extraEntries = ''
      menuentry "Windows Boot Manager" {
        insmod part_gpt
        insmod fat
        insmod chain
        search --no-floppy --file --set=root /EFI/Microsoft/Boot/bootmgfw.efi
        chainloader /EFI/Microsoft/Boot/bootmgfw.efi
      }
    '';
  };

  networking.interfaces.enp3s0.wakeOnLan.enable = true;
  systemd.services.wol-enp3s0 = {
    description = "Enable Wake on LAN for enp3s0";
    after = [ "network-addresses-enp3s0.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.ethtool}/sbin/ethtool -s enp3s0 wol g";
    };
  };

  services.logind.settings.Login = {
    IdleAction = "ignore";
    HandlePowerKey = "poweroff";
  };

  # Intermittent (WoL-woken) node: the taint keeps its shutdowns off always-on
  # workloads; CPU/batch jobs opt in via toleration + node-pool. The GTX 680 is
  # Kepler, which current drivers dropped, so the GPU is not wired into k3s.
  homelab.k3s.serverAddr = "https://192.168.10.154:6443"; # k3s server on lenovo-21CB001PMX
  homelab.k3s.cni = "cilium"; # must match control-plane: Cilium KPR, kube-proxy disabled
  homelab.k3s.extraFlags = [
    "--node-label=node-pool=workers"
    "--node-taint=sammasak.dev/intermittent=true:NoSchedule"
    # NOTE: no graceful-shutdown args. `shutdownGracePeriod` is a kubelet
    # config-file field, NOT a CLI flag — passing it via --kubelet-arg makes
    # kubelet exit with "unknown flag" and crashloops the node. Not worth a
    # kubelet config file for an opt-in node that runs nothing critical.
  ];
}
