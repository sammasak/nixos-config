# k3s agent (worker) module
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.homelab.k3s;
in
{
  imports = [ ./default.nix ];

  config = mkIf (cfg.enable && cfg.role == "agent") {
    # Agent nodes need minimal additional configuration
    # The default.nix handles most settings

    # Note: kubernetes.io/node-role labels are restricted by kubelet
    # They should be applied via kubectl after the node joins, or use custom labels
    # Worker nodes don't require special labels - they're identified by absence of control-plane role
  };
}
