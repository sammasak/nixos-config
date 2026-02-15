# LightDM display manager (X11)
{ config, lib, ... }:
let
  displayManager = config.sam.profile.displayManager;
in
{
  config = lib.mkIf (displayManager == "lightdm") {
    services.xserver.displayManager.lightdm = {
      enable = true;
      greeters.gtk.enable = true;
    };
  };
}

