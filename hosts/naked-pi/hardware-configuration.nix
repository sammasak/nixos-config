# Stock NixOS aarch64 SD image layout, same as black-pi: on a Pi 3 the firmware's
# [pi3] section chains u-boot-rpi3.bin, which loads extlinux.conf from /boot on root.
# Labels, not UUIDs: the image stamps a fixed 4444…-8888 root UUID.
{ lib, modulesPath, pkgs, ... }:
{
  # Without it the brcmfmac onboard radio and most USB Wi-Fi adapters have no firmware.
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [ "usbhid" "usb_storage" ];

  # Ships brcm/BCM43430A1.hcd — the onboard BT firmware patch. Without it
  # hci_uart_bcm detects the chip but Read-Local-Name times out (hci0 unusable).
  hardware.firmware = [ pkgs.raspberrypiWirelessFirmware ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
  };

  fileSystems."/boot/firmware" = {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
    options = [ "nofail" "noauto" ];
  };

  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
}
