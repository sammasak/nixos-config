# Homelab k3s server role
# Use this role for control plane nodes
{ ... }:
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

  # Server role defaults
  homelab.k3s = {
    enable = true;
    role = "server";
  };

  # Tailscale subnet router for control plane node
  homelab.tailscale.enable = true;

}
