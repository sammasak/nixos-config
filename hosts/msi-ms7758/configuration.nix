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

  # Shared Windows ESP is only 100 MiB; keep kernels/initrds on root FS.
  boot.loader.grub.copyKernels = false;
  boot.loader.grub.configurationLimit = 5;

  # Desktop tower: no automatic suspend/hibernate behavior.
  services.logind.settings.Login = {
    IdleAction = "ignore";
    HandlePowerKey = "poweroff";
  };
}
