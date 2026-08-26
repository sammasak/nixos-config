# Homelab k3s agent role
# Use this role for worker nodes
{ ... }:
{
  imports = [
    ./base.nix
    ../core/always-on.nix
    ../homelab/k3s/agent.nix
    ../homelab/tailscale.nix
  ];

  # Agent role defaults
  homelab.k3s = {
    enable = true;
    role = "agent";
  };

  # Every worker joins the tailnet directly, as a plain client.
  #
  # Before this, Tailscale only ran on the control plane as a subnet router, so
  # remote access to a worker went through it: if the control plane was down or
  # unreachable, so was every worker — exactly when you most need a shell on
  # one. A direct client gives each worker its own independent path in.
  #
  # Client mode advertises nothing, accepts no routes or DNS from the tailnet,
  # and does not enable Tailscale SSH; see modules/homelab/tailscale.nix for why
  # each of those is off.
  homelab.tailscale = {
    enable = true;
    mode = "client";
  };
}
