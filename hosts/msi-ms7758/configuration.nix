# Host configuration for msi-ms7758
{ lib, pkgs, ... }:
let
  vars = import ./variables.nix;
in
{
  imports = [
    ./hardware-configuration.nix

    # Hardware
    ../../modules/hardware/video/${vars.videoDriver}.nix

    # Keep GRUB theming consistent with the other machines (Stylix).
    ../../modules/themes/Catppuccin
  ];

  sam.profile = vars;
  sam.secrets.enable = true;

  # GPU worker: prepare NVIDIA for container workloads.
  #
  # We use CDI (Container Device Interface) generation via the NixOS module.
  # The cluster-side NVIDIA device plugin can then use `cdi-annotations` or
  # `cdi-cri` modes, as long as containerd has CDI enabled.
  hardware.nvidia-container-toolkit.enable = true;

  # Shared Windows ESP is only 100 MiB; keep the GRUB menu short.
  boot.loader.grub.configurationLimit = 5;

  # This machine has a tiny Windows ESP mounted at /boot (~100 MiB).
  #
  # NixOS's GRUB installer forces copying kernels/initrds when the GRUB "boot
  # directory" is on a different filesystem than /nix/store. Since /boot is
  # VFAT on a separate partition, that would fill /boot and break rebuilds.
  #
  # Fix: keep EFI files on /boot (ESP) but store GRUB's directory (and config)
  # on the root filesystem, where space isn't constrained.
  boot.loader.grub.mirroredBoots = lib.mkForce [
    {
      path = "/boot-nix";
      efiSysMountPoint = "/boot";
      devices = [ "nodev" ];
    }
  ];

  # Windows entry for GRUB (works when booted in UEFI mode).
  boot.loader.grub.extraEntries = ''
    menuentry "Windows Boot Manager" {
      insmod part_gpt
      insmod fat
      insmod chain
      search --no-floppy --file --set=root /EFI/Microsoft/Boot/bootmgfw.efi
      chainloader /EFI/Microsoft/Boot/bootmgfw.efi
    }
  '';

  # Wake on LAN — magic packet on the onboard NIC.
  # The .link file (via wakeOnLan.enable) is processed by udev at boot.
  # The explicit service ensures WoL is set via ethtool after every boot,
  # regardless of udev timing, so the NIC is always ready to receive magic packets.
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

  # Desktop tower: no automatic suspend/hibernate behavior.
  services.logind.settings.Login = {
    IdleAction = "ignore";
    HandlePowerKey = "poweroff";
  };

  # k3s agent configuration (worker node by default)
  homelab.k3s.serverAddr = "https://192.168.10.154:6443"; # k3s server on lenovo-21CB001PMX
  homelab.k3s.extraFlags = [
    "--node-label=node-pool=workers"
    "--node-label=gpu=nvidia"
  ];

  # Enable CDI support in k3s's embedded containerd so GPU devices can be
  # injected using CDI (for example via NVIDIA device plugin `cdi-annotations`).
  #
  # See:
  # - https://docs.k3s.io/advanced#configuring-containerd
  # - https://github.com/cncf-tags/container-device-interface
  services.k3s.containerdConfigTemplate = ''
    {{ template "base" . }}

    [plugins."io.containerd.grpc.v1.cri"]
      enable_cdi = true
      cdi_spec_dirs = ["/etc/cdi", "/var/run/cdi"]
  '';

  # Best-effort ordering: generate CDI spec before k3s starts.
  systemd.services.k3s = {
    wants = [ "nvidia-container-toolkit-cdi-generator.service" ];
    after = [ "nvidia-container-toolkit-cdi-generator.service" ];
  };
}
