{ lib, ... }:
let
  vars = import ./variables.nix;
in
{
  imports = [ ./hardware-configuration.nix ];

  sam.profile = vars;

  # No UEFI: the Pi firmware chains U-Boot, which reads /boot/extlinux.
  # https://wiki.nixos.org/wiki/NixOS_on_ARM/Raspberry_Pi_3
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;
  boot.loader.generic-extlinux-compatible.configurationLimit = 4;

  # The SD image creates root with an empty password; mutableUsers would keep it.
  users.users.root.hashedPassword = "!";
}
