{ lib, pkgs, ... }:
{
  hardware.graphics = {
    enable = true;
    # No 32-bit GL consumers on these hosts; mkDefault so Steam (msi's gaming entry) can turn it on.
    enable32Bit = lib.mkDefault false;
    extraPackages = with pkgs; [
      intel-media-driver
      intel-vaapi-driver
      libva-vdpau-driver
      libvdpau-va-gl
    ];
  };
}
