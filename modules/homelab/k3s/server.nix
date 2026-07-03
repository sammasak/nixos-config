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

    # Disable bundled local-storage and metrics-server; custom versions are
    # deployed via k3s-manifests.service below.
    homelab.k3s.disableComponents = [ "traefik" "servicelb" "local-storage" "metrics-server" ];

    # k3s 1.35 added a staging step that tries to write bundled manifests to
    # the manifests dir. The NixOS k3s module creates L+ symlinks (Nix store,
    # read-only) there, so the write fails. Fix: copy real files before k3s
    # starts instead of relying on symlinks.
    systemd.services.k3s-manifests = {
      description = "Copy k3s custom manifests (writable, not symlinks)";
      wantedBy = [ "k3s.service" ];
      before = [ "k3s.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "k3s-manifests-copy" ''
          mkdir -p /var/lib/rancher/k3s/server/manifests/metrics-server
          cp --remove-destination ${./manifests/local-storage.yaml} /var/lib/rancher/k3s/server/manifests/local-storage.yaml
          cp --remove-destination ${./manifests/metrics-server-deployment.yaml} /var/lib/rancher/k3s/server/manifests/metrics-server/metrics-server-deployment.yaml
        '';
      };
    };

    # Create kubeconfig symlink for easier access
    system.activationScripts.k3sKubeconfig = stringAfter [ "users" ] ''
      mkdir -p /home/${config.users.users.lukas.name or "lukas"}/.kube
      ln -sf /etc/rancher/k3s/k3s.yaml /home/${config.users.users.lukas.name or "lukas"}/.kube/config 2>/dev/null || true
    '';
  };
}
