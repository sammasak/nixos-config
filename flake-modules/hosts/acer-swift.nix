let
  vars = import ../../hosts/acer-swift/variables.nix;
in
{
  configurations.nixos.acer-swift = {
    hostDir = "acer-swift";
    inherit (vars) username roles;
  };
}
