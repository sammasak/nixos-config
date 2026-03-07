let
  vars = import ../../hosts/lenovo-21CB001PMX/variables.nix;
in
{
  configurations.nixos.lenovo = {
    hostDir = "lenovo-21CB001PMX";
    system = "x86_64-linux";
    username = vars.username;
    roles = vars.roles or [ "base" ];
  };
}
