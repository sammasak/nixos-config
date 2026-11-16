{
  config,
  lib,
  ...
}:
{
  imports = [ ./hardware-configuration.nix ];

  sam.profile = {
    username = "lukas";
    hostname = "asus-b460m";
    nativeOtel = true;
  };
  sam.herdr.trustedDirs = map (d: "/home/${config.sam.profile.username}/${d}") [
    "nixos-config"
    ".cache/wt"
  ];

  # Dual boot on Windows' 256 MB ESP, too small for systemd-boot's kernels: as msi, only the GRUB loader goes
  # there, its directory stays on root, and Windows is a hand-written entry (os-prober off).
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
