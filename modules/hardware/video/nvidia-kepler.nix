# NVIDIA (Kepler) driver for older GPUs (example: GeForce GTX 680).
#
# Notes:
# - Kepler GPUs are only supported by the legacy 470xx driver series.
# - Newer kernels regularly break legacy NVIDIA branches; use an LTS kernel.
{ config, pkgs, ... }:
{
  # Required by recent nixpkgs to build/install NVIDIA drivers.
  nixpkgs.config.nvidia.acceptLicense = true;

  # Default repo setting is linuxPackages_latest; override to an LTS kernel for
  # legacy NVIDIA driver compatibility.
  boot.kernelPackages = pkgs.linuxPackages_6_12;

  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.graphics = {
    enable = true;
    enable32Bit = true; # Steam/Proton needs 32-bit graphics libs
  };

  hardware.nvidia = {
    # Required for Wayland compositors like Hyprland.
    modesetting.enable = true;

    # The open kernel module does not apply to 470xx.
    open = false;

    nvidiaSettings = true;

    # Kepler / GTX 600-700 (non-Maxwell+) uses legacy 470xx.
    package = config.boot.kernelPackages.nvidiaPackages.legacy_470;
  };
}
