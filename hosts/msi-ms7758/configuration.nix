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
  ];

  sam.profile = vars;

  # Keep /boot on the root filesystem and mount the (shared) Windows ESP at /boot/efi.
  # The Windows ESP is only 100 MiB and cannot hold multiple NixOS kernel+initrd pairs.
  boot.loader.efi.efiSysMountPoint = "/boot/efi";

  # This machine is currently booted in legacy/CSM mode, so EFI variables are unavailable
  # and efibootmgr can't register a new boot entry. Install GRUB without touching NVRAM
  # and place a fallback loader at EFI/BOOT/BOOTX64.EFI so we can reboot into UEFI later.
  boot.loader.efi.canTouchEfiVariables = false;
  boot.loader.grub.efiInstallAsRemovable = true;

  # Shared Windows ESP is only 100 MiB; keep kernels/initrds on root FS.
  boot.loader.grub.copyKernels = false;
  boot.loader.grub.configurationLimit = 5;

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

  # Desktop tower: no automatic suspend/hibernate behavior.
  services.logind.settings.Login = {
    IdleAction = "ignore";
    HandlePowerKey = "poweroff";
  };

  # k3s agent configuration (worker node by default)
  homelab.k3s.serverAddr = "https://192.168.10.154:6443"; # k3s server on lenovo-21CB001PMX
  homelab.k3s.extraFlags = [
    "--node-label=node-pool=workers"
  ];
}
