# Desktop role (display manager + theme + desktop stack)
{ config, ... }:
{
  assertions = [
    {
      assertion = config.sam.profile.desktop == "hyprland";
      message = "Unsupported desktop `${config.sam.profile.desktop}`. Add a matching desktop role aspect before enabling it.";
    }
  ];

  imports = [
    ../core/sddm.nix
    ../themes/Catppuccin
    ../desktop/hyprland
  ];
}
