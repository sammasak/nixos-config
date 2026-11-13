let
  vars = import ../../hosts/black-pi/variables.nix;
in
{
  configurations.nixos.black-pi = {
    hostDir = "black-pi";
    inherit (vars) username roles;
  };
}
