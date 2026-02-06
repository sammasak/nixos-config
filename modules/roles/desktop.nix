# Desktop role (display manager + theme + desktop stack)
{ host, ... }:
let
  vars = import ../../hosts/${host}/variables.nix;
in
{
  imports = [
    ../core/sddm.nix
    ../themes/Catppuccin
    ../desktop/${vars.desktop}
  ];
}
