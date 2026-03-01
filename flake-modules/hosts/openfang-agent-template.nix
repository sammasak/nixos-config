let
  vars = import ../../hosts/openfang-agent-template/variables.nix;
in
{
  configurations.nixos.openfang-agent-template = {
    hostDir = "openfang-agent-template";
    system = "x86_64-linux";
    username = vars.username;
    roles = vars.roles or [ "base" ];
  };
}
