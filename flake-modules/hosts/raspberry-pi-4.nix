let
  vars = import ../../hosts/raspberry-pi-4/variables.nix;
in
{
  configurations.nixos.raspberry-pi-4 = {
    hostDir = "raspberry-pi-4";
    system = "aarch64-linux";
    username = vars.username;
    roles = vars.roles;
  };
}
