# Stock NixOS aarch64 SD image layout (nixos/modules/installer/sd-card):
# U-Boot on the FIRMWARE partition loads extlinux.conf from /boot on root.
# Labels, not UUIDs: the image stamps a fixed 4444…-8888 root UUID.
{ lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "usbhid" "usb_storage" ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
  };

  # Firmware and U-Boot only; nothing at runtime needs it mounted.
  fileSystems."/boot/firmware" = {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
    options = [ "nofail" "noauto" ];
  };

  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
}
