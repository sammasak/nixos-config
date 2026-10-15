{ lib, pkgs, ... }:
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

  # The SD image creates root with an empty password, and with mutableUsers an
  # existing user's hashedPassword is never applied, so lock it imperatively.
  system.activationScripts.lockEmptyRootPassword = {
    deps = [ "users" ];
    text = ''
      if [ -z "$(${pkgs.getent}/bin/getent shadow root | cut -d: -f2)" ]; then
        ${pkgs.shadow}/bin/usermod -p '!' root
      fi
    '';
  };
}
