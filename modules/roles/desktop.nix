# Desktop role (display manager + theme + desktop stack)
{ pkgs, inputs, ... }:
let
  colmenaPkg =
    if inputs.colmena.packages.${pkgs.system} ? colmena
    then inputs.colmena.packages.${pkgs.system}.colmena
    else inputs.colmena.packages.${pkgs.system}.default;
in
{
  imports = [
    ../core/sddm.nix
    ../themes/Catppuccin
    ../desktop/hyprland
  ];

  # Let any desktop machine act as a Colmena controller.
  environment.systemPackages = [ colmenaPkg ];
}
