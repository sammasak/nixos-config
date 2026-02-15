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

  # Hyprland on legacy NVIDIA drivers (470xx) can crash when EGL/GBM modifiers
  # are enabled. This disables them for Hyprland sessions.
  #
  # If you later switch this host to a modern NVIDIA GPU/driver, we can revisit
  # and potentially drop this.
  environment.sessionVariables.HYPRLAND_EGL_NO_MODIFIERS = "1";

  # Aquamarine (Hyprland's DRM backend) tends to be unstable on 470xx when using
  # atomic KMS + modifiers. Symptoms include black/garbled screen regions or
  # shifted output after login. Disable both for stability.
  environment.sessionVariables.AQ_NO_ATOMIC = "1";
  environment.sessionVariables.AQ_NO_MODIFIERS = "1";

  # Some 470xx + GBM setups appear to produce scanout corruption unless we force
  # a linear blit path for the final KMS buffer.
  environment.sessionVariables.AQ_FORCE_LINEAR_BLIT = "1";
}
