let
  vars = import ../../hosts/black-pi/variables.nix;
in
{
  configurations.nixos.black-pi = {
    hostDir = "black-pi";
    system = "aarch64-linux";
    inherit (vars) username roles;
  };
}
