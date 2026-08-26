# Homelab k3s server role
# Use this role for control plane nodes
{ lib, pkgs, config, ... }:
let
  username = config.sam.profile.username;
in
{
  imports = [
    ./base.nix
    ../core/always-on.nix
    ../homelab/k3s/server.nix
    ../homelab/adguardhome.nix
    ../homelab/acme.nix
    ../homelab/tailscale.nix
    ../homelab/ntfy.nix
    ../homelab/cluster-watchdog.nix
    ../homelab/nixos-rebuild-trigger.nix
  ];

  # claude-ctl CLI tool for managing agents
  environment.systemPackages = [ pkgs.claude-ctl ];

  # Server role defaults
  homelab.k3s = {
    enable = true;
    role = "server";
  };

  # Tailscale subnet router for control plane node
  homelab.tailscale.enable = true;

}
