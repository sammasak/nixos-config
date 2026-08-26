# Homelab k3s agent role
# Use this role for worker nodes
{ ... }:
{
  imports = [
    ./base.nix
    ../core/always-on.nix
    ../homelab/k3s/agent.nix
  ];

  # Agent role defaults
  homelab.k3s = {
    enable = true;
    role = "agent";
  };

}
