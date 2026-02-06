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

    # Optional: node labels for scheduling
    homelab.k3s.extraFlags = [
      "--node-label=node-role.kubernetes.io/worker=true"
    ];
  };
}
