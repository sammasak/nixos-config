{ config, lib, pkgs, ... }:

let
  inherit (lib) mkIf stringAfter;
  inherit (import ../../../lib/firewall.nix lib) mkDualBackendFirewall;
  cfg = config.homelab.k3s;

  # Control-plane management ports. 2379/2380 have no listener on this cluster
  # (it runs the embedded sqlite/kine datastore, not etcd) but stay declared so
  # a future HA etcd inherits the same scoping instead of being opened wide.
  apiPorts = [
    6443 # Kubernetes API server
    2379 # etcd client requests
    2380 # etcd peer communication
  ];

  apiSources = [
    config.sam.profile.lanCidr # agents (acer-swift) and admin workstations
    "10.42.0.0/16" # k3s pod CIDR — Cilium native-routing keeps the pod source IP
    "10.43.0.0/16" # k3s service CIDR — ClusterIP hairpin back to the apiserver
  ];

  apiInterfaces = [
    "lo" # kubectl / kubelet on the control plane itself
    "tailscale0" # remote admins over the tailnet
  ];

  apiRules = mkDualBackendFirewall {
    comment = "k3s control-plane API + etcd: LAN, cluster networks and tailnet only.";
    ports = apiPorts;
    sources = apiSources;
    interfaces = apiInterfaces;
    backend = config.networking.firewall.backend;
  };
in
{
  imports = [
    ./default.nix
    ../flux.nix
  ];

  config = mkIf (cfg.enable && cfg.role == "server") {
    # `lo` and `tailscale0` are already in `trustedInterfaces` (the latter via
    # ../tailscale.nix), so accepting on them here is belt-and-braces should the
    # trusted set ever be trimmed.
    networking.firewall = {
      inherit (apiRules) extraInputRules extraCommands;
    };

    environment.systemPackages = with pkgs; [
      fluxcd        # GitOps toolkit
      sops          # Secret management
      age           # Encryption for sops
    ];

    # local-storage is replaced by a resource-limited copy in k3s-manifests below.
    # metrics-server stays off: nothing depends on metrics.k8s.io — autoscaling is
    # all KEDA (external.metrics.k8s.io) and no HPA uses Resource metrics.
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

    # A private 0600 COPY, not a symlink to the 644 source: that let any local
    # account read cluster-admin credentials. Re-copied every activation so cert
    # rotation propagates. Honest limit: code running AS the operator still reads it.
    system.activationScripts.k3sKubeconfig = stringAfter [ "users" ] ''
      u=${config.sam.profile.username}
      if [ -f /etc/rancher/k3s/k3s.yaml ]; then
        mkdir -p /home/$u/.kube
        rm -f /home/$u/.kube/config
        cp /etc/rancher/k3s/k3s.yaml /home/$u/.kube/config
        chown $u /home/$u/.kube/config
        chmod 0600 /home/$u/.kube/config
      fi
    '';
  };
}
