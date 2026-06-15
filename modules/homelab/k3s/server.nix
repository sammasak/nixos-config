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
    # limits. k3s ≥1.35 (NixOS 26.11) opens each manifest for writing during
    # the "stage files" phase at startup. services.k3s.manifests populates the
    # manifests directory via systemd tmpfiles symlinks into the read-only
    # /nix/store, causing EROFS on every start. Copy real files before k3s
    # starts instead. The .skip files prevent k3s from staging its own bundled
    # copy; our replacement manifests are then applied by the deploy controller.
    systemd.services.k3s.preStart = let
      localStorageSkip = pkgs.writeText "local-storage-skip"
        "# bundled manifest skipped; see local-storage.yaml override\n";
      metricsSkip = pkgs.writeText "metrics-server-deployment-skip"
        "# bundled manifest skipped; see metrics-server-deployment.yaml override\n";
    in ''
      mkdir -p /var/lib/rancher/k3s/server/manifests/metrics-server
      rm -f /var/lib/rancher/k3s/server/manifests/local-storage.yaml.skip
      rm -f /var/lib/rancher/k3s/server/manifests/local-storage.yaml
      rm -f /var/lib/rancher/k3s/server/manifests/metrics-server/metrics-server-deployment.yaml.skip
      rm -f /var/lib/rancher/k3s/server/manifests/metrics-server/metrics-server-deployment.yaml
      install -m 0644 ${localStorageSkip} /var/lib/rancher/k3s/server/manifests/local-storage.yaml.skip
      install -m 0644 ${./manifests/local-storage.yaml} /var/lib/rancher/k3s/server/manifests/local-storage.yaml
      install -m 0644 ${metricsSkip} /var/lib/rancher/k3s/server/manifests/metrics-server/metrics-server-deployment.yaml.skip
      install -m 0644 ${./manifests/metrics-server-deployment.yaml} /var/lib/rancher/k3s/server/manifests/metrics-server/metrics-server-deployment.yaml
    '';

    # Create kubeconfig symlink for easier access
    system.activationScripts.k3sKubeconfig = stringAfter [ "users" ] ''
      mkdir -p /home/${config.users.users.lukas.name or "lukas"}/.kube
      ln -sf /etc/rancher/k3s/k3s.yaml /home/${config.users.users.lukas.name or "lukas"}/.kube/config 2>/dev/null || true
    '';
  };
}
