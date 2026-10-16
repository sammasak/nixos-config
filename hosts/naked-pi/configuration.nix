{ lib, ... }:
let
  vars = import ./variables.nix;
in
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/hardware/sd-image-root-lock.nix
  ];

  sam.profile = vars;

  # No UEFI: the Pi firmware chains U-Boot, which reads /boot/extlinux.
  # https://wiki.nixos.org/wiki/NixOS_on_ARM/Raspberry_Pi_3
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;
  boot.loader.generic-extlinux-compatible.configurationLimit = 4;
}
