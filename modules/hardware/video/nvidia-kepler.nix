# NVIDIA (Kepler) driver for older GPUs (example: GeForce GTX 680).
#
# Notes:
# - Kepler GPUs are only supported by the legacy 470xx driver series.
# - Newer kernels regularly break legacy NVIDIA branches; use an LTS kernel.
{ config, pkgs, lib, ... }:
let
  profile = config.sam.profile or { };
  hasDesktop = builtins.elem "desktop" (profile.roles or [ ]);
  wants32Bit = profile.games or false;
in
{
  # Required by recent nixpkgs to build/install NVIDIA drivers.
  nixpkgs.config.nvidia.acceptLicense = true;

  # Default repo setting is linuxPackages_latest; override to an LTS kernel for
  # legacy NVIDIA driver compatibility.
  boot.kernelPackages = pkgs.linuxPackages_6_12;

  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.graphics = {
    enable = true;
    # 32-bit GL/Vulkan libs are mainly needed for Steam/Proton.
    enable32Bit = lib.mkDefault wants32Bit;
  };

  hardware.nvidia = {
    # Enable DRM KMS for the proprietary driver (required for modern setups and
    # generally recommended even on X11).
    modesetting.enable = true;

    # The open kernel module does not apply to 470xx.
    open = false;

    nvidiaSettings = lib.mkDefault hasDesktop;

    # Kepler / GTX 600-700 (non-Maxwell+) uses legacy 470xx.
    package = config.boot.kernelPackages.nvidiaPackages.legacy_470;
  };
}
