# GRUB beside Windows on Windows' own ESP (msi-ms7758, asus-b460m), imported by the host: the ESP is too small for
# systemd-boot's kernels, so only GRUB's EFI loader goes there, its directory stays on root (/boot-nix), and Windows is
# a hand-written entry (os-prober off) that finds bootmgfw.efi on whichever partition holds it.
{ config, lib, ... }:
let
  esps = map (b: b.efiSysMountPoint) config.boot.loader.grub.mirroredBoots;
  notEsp = lib.filter (m: (config.fileSystems.${m}.fsType or null) != "vfat") esps;
in
{
  # a loader written to a mount that is not the vfat ESP the firmware reads leaves the machine booting Windows only
  assertions = [
    {
      assertion = notEsp == [ ];
      message = "windows-dual-boot.nix: GRUB's efiSysMountPoint ${toString notEsp} is not a vfat filesystem in fileSystems; it must be Windows' ESP, which holds bootmgfw.efi and GRUB's loader.";
    }
  ];

  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.grub = {
    enable = true;
    device = "nodev";
    efiSupport = true;
    useOSProber = false;
    configurationLimit = 5;
    mirroredBoots = lib.mkForce [
      {
        path = "/boot-nix";
        efiSysMountPoint = "/boot";
        devices = [ "nodev" ];
      }
    ];
    extraEntries = ''
      menuentry "Windows Boot Manager" {
        insmod part_gpt
        insmod fat
        insmod chain
        search --no-floppy --file --set=root /EFI/Microsoft/Boot/bootmgfw.efi
        chainloader /EFI/Microsoft/Boot/bootmgfw.efi
      }
    '';
  };
}
