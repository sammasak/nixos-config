# Intel Graphics Driver
{ pkgs, ... }:
{
  hardware.graphics = {
    enable = true;
    # No 32-bit GL consumers on these hosts. Re-enable for Steam/Wine.
    enable32Bit = false;
    extraPackages = with pkgs; [
      intel-media-driver
      intel-vaapi-driver
      libva-vdpau-driver
      libvdpau-va-gl
    ];
  };
}
