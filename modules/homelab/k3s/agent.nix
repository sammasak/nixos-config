{ config, lib, ... }:

let
  inherit (lib) mkIf;
  cfg = config.homelab.k3s;
in
{
  imports = [ ./default.nix ];

  # Deliberately empty: ./default.nix carries every agent setting. Kept as the
  # role's named seam, and because kubelet rejects kubernetes.io/node-role
  # labels — a worker is identified by the absence of the control-plane role,
  # so there is nothing to set here.
  config = mkIf (cfg.enable && cfg.role == "agent") { };
}
