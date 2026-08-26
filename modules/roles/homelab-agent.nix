# Homelab k3s agent role
# Use this role for worker nodes
{ lib, pkgs, ... }:
{
  imports = [
    ./base.nix
    ../core/always-on.nix
    ../homelab/k3s/agent.nix
  ];

  # claude-ctl CLI tool for managing agents
  environment.systemPackages = [ pkgs.claude-ctl ];

  # Agent role defaults
  homelab.k3s = {
    enable = true;
    role = "agent";
  };

}
