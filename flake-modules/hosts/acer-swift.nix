let
  vars = import ../../hosts/acer-swift/variables.nix;
in
{
  configurations.nixos.acer-swift = {
    hostDir = "acer-swift";
    system = "x86_64-linux";
    username = vars.username;
    roles = vars.roles or [ "base" ];
  };
}
