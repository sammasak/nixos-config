# Not a machine: scripts/test-seventh-host.py copies this directory to hosts/seventh in a temporary tree. Only base's
# requirements: the user, a root filesystem, a platform; no secrets, so no sops recipient.
{
  sam.profile = {
    username = "lukas";
    hostname = "seventh";
    devTools = false;
  };
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
  };
  nixpkgs.hostPlatform = "x86_64-linux";
}
