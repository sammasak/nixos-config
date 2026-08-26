# k3s server (control plane) module
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.homelab.k3s;

  # Control-plane management ports. 2379/2380 have no listener on this cluster
  # (it runs the embedded sqlite/kine datastore, not etcd) but stay declared so
  # a future HA etcd inherits the same scoping instead of being opened wide.
  apiPorts = [
    6443 # Kubernetes API server
    2379 # etcd client requests
    2380 # etcd peer communication
  ];

  # Source networks allowed to reach the ports above.
  apiSources = [
    config.sam.profile.lanCidr # agents (acer-swift) and admin workstations
    "10.42.0.0/16" # k3s pod CIDR — Cilium native-routing keeps the pod source IP
    "10.43.0.0/16" # k3s service CIDR — ClusterIP hairpin back to the apiserver
  ];

  # Interfaces that may always reach them, independent of source address.
  apiInterfaces = [
    "lo" # kubectl / kubelet on the control plane itself
    "tailscale0" # remote admins over the tailnet
  ];

  nftPorts = concatMapStringsSep ", " toString apiPorts;
  nftSources = concatStringsSep ", " apiSources;
in
{
  imports = [
    ./default.nix
    ../flux.nix
  ];

  config = mkIf (cfg.enable && cfg.role == "server") {
    # Server-specific firewall rules.
    #
    # The API/etcd ports are deliberately NOT listed in `allowedTCPPorts` —
    # that option accepts them from any source. They are instead accepted only
    # from `apiSources` and `apiInterfaces` above. `lo` and `tailscale0` are
    # already in `trustedInterfaces` (the latter via ../tailscale.nix), so those
    # rules are belt-and-braces should the trusted set ever be trimmed.
    #
    # Both backends are targeted because they read different options and this
    # tree currently runs the iptables backend:
    #   * `extraInputRules` — nftables backend only (appended to input-allow).
    #   * `extraCommands`   — iptables backend only; the nftables backend
    #     asserts it is empty, hence the explicit backend guard.
    networking.firewall = {
      extraInputRules = ''
        # k3s control-plane API + etcd: LAN, cluster networks and tailnet only.
        ${concatMapStringsSep "\n" (i: ''iifname "${i}" tcp dport { ${nftPorts} } accept'') apiInterfaces}
        ip saddr { ${nftSources} } tcp dport { ${nftPorts} } accept
      '';

      extraCommands = optionalString (config.networking.firewall.backend == "iptables") (
        concatStrings (
          map (
            port:
            concatMapStrings (iface: ''
              ip46tables -w -A nixos-fw -i ${iface} -p tcp --dport ${toString port} -j nixos-fw-accept
            '') apiInterfaces
            + concatMapStrings (src: ''
              iptables -w -A nixos-fw -s ${src} -p tcp --dport ${toString port} -j nixos-fw-accept
            '') apiSources
          ) apiPorts
        )
      );
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
