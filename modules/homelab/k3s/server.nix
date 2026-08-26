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

    # Disable bundled local-storage (a custom, resource-limited version is
    # deployed via k3s-manifests.service below) and metrics-server.
    #
    # metrics-server is intentionally NOT run on this cluster: nothing depends on
    # metrics.k8s.io. All autoscaling goes through KEDA (external.metrics.k8s.io),
    # and no HPA uses Resource (cpu/memory) metrics. The bundled addon stays
    # disabled here and no override manifest is shipped for it. See infra-042.
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
          cp --remove-destination ${./manifests/local-storage.yaml} /var/lib/rancher/k3s/server/manifests/local-storage.yaml
          # infra-042: remove the stale metrics-server override left by earlier
          # deploys. metrics-server is disabled and no longer shipped as a manifest.
          rm -rf /var/lib/rancher/k3s/server/manifests/metrics-server
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
