# Workstation image template (used for KubeVirt image builds).
{ ... }:
let
  vars = import ./variables.nix;
in
{
  imports = [
    ../../modules/homelab/workstation-image.nix
  ];

  sam.profile = vars;

  homelab.workstation.enable = true;
}
