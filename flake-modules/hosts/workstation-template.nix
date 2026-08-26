let
  vars = import ../../hosts/workstation-template/variables.nix;
in
{
  configurations.nixos.workstation-template = {
    hostDir = "workstation-template";
    system = "x86_64-linux";
    username = vars.username;
    roles = vars.roles or [ "base" ];
  };
}
