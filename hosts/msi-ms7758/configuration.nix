# Host configuration for msi-ms7758
{ ... }:
let
  vars = import ./variables.nix;
in
{
  imports = [
    ./hardware-configuration.nix
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

  # Desktop tower: no automatic suspend/hibernate behavior.
  services.logind.settings.Login = {
    IdleAction = "ignore";
    HandlePowerKey = "poweroff";
  };
}
