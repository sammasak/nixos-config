let
  vars = import ../../hosts/claude-worker-template/variables.nix;
in
{
  configurations.nixos.claude-worker-template = {
    hostDir = "claude-worker-template";
    system = "x86_64-linux";
    username = vars.username;
    roles = vars.roles or [ "base" ];
  };
}
