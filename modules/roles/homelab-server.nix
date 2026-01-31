# Homelab k3s server role
# Use this role for control plane nodes
{ ... }:
{
  imports = [
    ./base.nix
    ../homelab/k3s/server.nix
  ];

  # Server role defaults
  homelab.k3s = {
    enable = true;
    role = "server";
  };
}
