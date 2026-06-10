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

    # Override two bundled addons with versions that have explicit resource
    # limits, so kube-system stays within the cluster's resource accounting
    # rules. The .skip files tell k3s not to write its bundled copy on startup
    # (per https://docs.k3s.io/installation/packaged-components#disabling-manifests).
    # The replacement manifests are then picked up by k3s' deploy controller.
    services.k3s.manifests = {
      local-storage-skip = {
        target = "local-storage.yaml.skip";
        source = pkgs.writeText "local-storage-skip" "# bundled manifest skipped; see local-storage.yaml override\n";
      };
      local-storage = {
        target = "local-storage.yaml";
        source = ./manifests/local-storage.yaml;
      };
      metrics-server-deployment-skip = {
        target = "metrics-server/metrics-server-deployment.yaml.skip";
        source = pkgs.writeText "metrics-server-deployment-skip" "# bundled manifest skipped; see metrics-server-deployment.yaml override\n";
      };
      metrics-server-deployment = {
        target = "metrics-server/metrics-server-deployment.yaml";
        source = ./manifests/metrics-server-deployment.yaml;
      };
    };

    # Create kubeconfig symlink for easier access
    system.activationScripts.k3sKubeconfig = stringAfter [ "users" ] ''
      mkdir -p /home/${config.users.users.lukas.name or "lukas"}/.kube
      ln -sf /etc/rancher/k3s/k3s.yaml /home/${config.users.users.lukas.name or "lukas"}/.kube/config 2>/dev/null || true
    '';
  };
}
