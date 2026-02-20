# Desktop role (display manager + theme + desktop stack)
{ ... }:
{
  imports = [
    ../core/sddm.nix
    ../themes/Catppuccin
    ../desktop/hyprland
  ];
}
