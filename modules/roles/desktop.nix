# Desktop role (display manager + theme + desktop stack)
{ host, pkgs, ... }:
let
  vars = import ../../hosts/${host}/variables.nix;
in
{
  imports = [
    ../core/sddm.nix
    ../themes/Catppuccin
    ../desktop/${vars.desktop}
  ];

  # Let any desktop machine act as a Colmena controller.
  environment.systemPackages = [ pkgs.colmena ];
}
