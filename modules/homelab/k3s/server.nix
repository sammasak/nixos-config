# k3s server (control plane) module
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.homelab.k3s;
in
{
  imports = [
    ./default.nix
    ../flux.nix
  ];

  config = mkIf (cfg.enable && cfg.role == "server") {
    # Server-specific firewall rules
    networking.firewall = {
      allowedTCPPorts = [
        6443  # Kubernetes API server
        2379  # etcd client requests
        2380  # etcd peer communication
      ];
    };

    # Additional server tools
    environment.systemPackages = with pkgs; [
      fluxcd        # GitOps toolkit
      sops          # Secret management
      age           # Encryption for sops
    ];

    # Create kubeconfig symlink for easier access
    system.activationScripts.k3sKubeconfig = stringAfter [ "users" ] ''
      mkdir -p /home/${config.users.users.lukas.name or "lukas"}/.kube
      ln -sf /etc/rancher/k3s/k3s.yaml /home/${config.users.users.lukas.name or "lukas"}/.kube/config 2>/dev/null || true
    '';
  };
}
