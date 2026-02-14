# Boot configuration
{ pkgs, lib, ... }:
{
  boot = {
    # Filesystems support
    supportedFilesystems = [
      "ntfs"
      "exfat"
      "ext4"
      "fat32"
      "btrfs"
    ];
    tmp.cleanOnBoot = true;
    kernelPackages = pkgs.linuxPackages_latest;
    kernelParams = [
      "preempt=full"
    ];
    loader = {
      efi.canTouchEfiVariables = true;
      # Default ESP mountpoint. Some hosts mount ESP at /boot/efi to keep /boot on
      # the root filesystem (useful when sharing a small Windows ESP).
      efi.efiSysMountPoint = lib.mkDefault "/boot";
      timeout = 3;
      grub = {
        enable = true;
        device = "nodev";
        efiSupport = true;
        useOSProber = false;
        gfxmodeEfi = "1920x1080";
        gfxmodeBios = "1920x1080";
        theme = lib.mkDefault (pkgs.stdenv.mkDerivation {
          pname = "distro-grub-themes";
          version = "3.1";
          src = pkgs.fetchFromGitHub {
            owner = "AdisonCavani";
            repo = "distro-grub-themes";
            rev = "v3.1";
            hash = "sha256-ZcoGbbOMDDwjLhsvs77C7G7vINQnprdfI37a9ccrmPs=";
          };
          installPhase = "cp -r customize/nixos $out";
        });
      };
    };
    # Appimage Support
    binfmt.registrations.appimage = {
      wrapInterpreterInShell = false;
      interpreter = "${pkgs.appimage-run}/bin/appimage-run";
      recognitionType = "magic";
      offset = 0;
      mask = ''\xff\xff\xff\xff\x00\x00\x00\x00\xff\xff\xff'';
      magicOrExtension = ''\x7fELF....AI\x02'';
    };
  };
}
