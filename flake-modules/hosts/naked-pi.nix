let
  vars = import ../../hosts/naked-pi/variables.nix;
in
{
  configurations.nixos.naked-pi = {
    hostDir = "naked-pi";
    inherit (vars) username roles;
  };
}
