let
  vars = import ../../hosts/acer-swift/variables.nix;
in
{
  configurations.nixos.acer-swift = {
    hostDir = "acer-swift";
    system = "x86_64-linux";
    inherit (vars) username roles;
  };
}
