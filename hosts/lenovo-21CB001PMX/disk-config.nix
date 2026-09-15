# Declares the current hand-partitioned layout for a future nixos-anywhere/
# disko-install reinstall. enableConfig=false keeps hardware-configuration.nix
# authoritative for the live system; disko generates nothing here.
{
  disko.enableConfig = false;

  disko.devices.disk.main = {
    device = "/dev/disk/by-id/nvme-SAMSUNG_MZVL2512HCJQ-00BL7_S64KNX1T235655";
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "fmask=0077" "dmask=0077" ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
