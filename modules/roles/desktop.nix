# Desktop role (display manager + theme + desktop stack)
{ config, ... }:
let
  desktop = config.sam.profile.desktop;
  supported = [ "hyprland" "i3" ];
in
{
  assertions = [
    {
      assertion = builtins.elem desktop supported;
      message = "Unsupported desktop `${desktop}`. Supported: ${builtins.concatStringsSep ", " supported}.";
    }
  ];

  imports = [
    ../core/sddm.nix
    ../core/lightdm.nix
    ../themes/Catppuccin
    ../desktop/hyprland
    ../desktop/i3
  ];
}
