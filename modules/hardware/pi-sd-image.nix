# Stock NixOS aarch64 SD image (nixos/modules/installer/sd-card): U-Boot on FIRMWARE loads
# extlinux.conf from /boot on root. Labels, not UUIDs: the image stamps a fixed 4444…-8888 root UUID.
{
  lib,
  modulesPath,
  pkgs,
  ...
}:
{
  # Without it the brcmfmac onboard radio and most USB Wi-Fi adapters have no firmware.
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
  };

  # Firmware and U-Boot only; nothing at runtime needs it mounted.
  fileSystems."/boot/firmware" = {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
    options = [
      "nofail"
      "noauto"
    ];
  };

  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";

  # No UEFI: the Pi firmware chains U-Boot, which reads /boot/extlinux.
  # https://wiki.nixos.org/wiki/NixOS_on_ARM/Raspberry_Pi
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

  # mkForce: the fleet's monthly 30-day GC (modules/core/automation.nix) can fill the SD card.
  nix.gc.dates = lib.mkForce "weekly";
  nix.gc.options = lib.mkForce "--delete-older-than 7d";

  # The image ships root with an empty password, and with mutableUsers a hashedPassword never reaches
  # a user the image already made: lock root at activation while still empty, closing console/serial
  # login and leaving a deliberately set password alone.
  system.activationScripts.lockEmptyRootPassword = {
    deps = [ "users" ];
    text = ''
      if [ -z "$(${pkgs.getent}/bin/getent shadow root | cut -d: -f2)" ]; then
        ${pkgs.shadow}/bin/usermod -p '!' root
      fi
    '';
  };
}
