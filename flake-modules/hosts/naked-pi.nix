let
  vars = import ../../hosts/naked-pi/variables.nix;
in
{
  configurations.nixos.naked-pi = {
    hostDir = "naked-pi";
    system = "aarch64-linux";
    username = vars.username;
    roles = vars.roles;
  };
}
