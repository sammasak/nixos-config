# Common k3s configuration shared between server and agent
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption optionals types;
  cfg = config.homelab.k3s;
in
{
  imports = [ ../sops.nix ];

  options.homelab.k3s = {
    enable = mkEnableOption "k3s Kubernetes";

    role = mkOption {
      type = types.enum [ "server" "agent" ];
      description = "Node role in the cluster";
    };

    clusterName = mkOption {
      type = types.str;
      default = "homelab";
      description = "Name of the k3s cluster";
    };

    serverAddr = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Address of the k3s server (required for agents)";
    };

    tokenFile = mkOption {
      type = types.nullOr types.path;
      # Read from the sops secret rather than repeating its path: ../sops.nix
      # is imported above and `homelab.secrets.enable` is forced true below, so
      # the secret is always declared in the same evaluation as this default.
      default = config.sops.secrets."k3s/cluster_token".path;
      defaultText = ''config.sops.secrets."k3s/cluster_token".path'';
      description = "Path to file containing the cluster token (managed by sops-nix)";
    };

    extraFlags = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Additional flags to pass to k3s";
    };

    flannel = {
      backend = mkOption {
        type = types.enum [ "vxlan" "host-gw" "wireguard-native" "none" ];
        default = "host-gw";
        description = "Flannel backend for pod networking (only used when cni = \"flannel\")";
      };
    };

    cni = mkOption {
      type = types.enum [ "flannel" "cilium" ];
      default = "flannel";
      description = ''
        CNI provider for the cluster.

        "flannel" (default) uses the bundled k3s flannel + embedded kube-proxy +
        embedded network-policy controller.

        "cilium" disables all three on the k3s side (--flannel-backend=none,
        --disable-kube-proxy, --disable-network-policy) so Cilium can be installed
        as the sole CNI with eBPF kube-proxy replacement and Hubble observability.
        Cilium itself is deployed out-of-band (helm) then managed via Flux.

        Must be set consistently on every node (server + all agents), since
        --disable-kube-proxy is a per-node flag.
      '';
    };

    disableComponents = mkOption {
      type = types.listOf types.str;
      default = [ "traefik" "servicelb" ];
      description = "Built-in k3s components to disable";
    };

    taintControlPlane = mkOption {
      type = types.bool;
      default = false;
      description = "Taint control plane to prevent regular workloads from scheduling (enable when workers are available)";
    };
  };

  config = mkIf cfg.enable {
    homelab.secrets.enable = true;

    assertions = [
      {
        assertion = cfg.tokenFile != null;
        message = "homelab.k3s.tokenFile must be set (use sops-nix to manage the secret)";
      }
      {
        assertion = cfg.role == "server" || cfg.serverAddr != null;
        message = "homelab.k3s.serverAddr must be set for agent nodes";
      }
    ];

    services.k3s = {
      enable = true;
      role = cfg.role;
      tokenFile = cfg.tokenFile;
      serverAddr = mkIf (cfg.role == "agent") cfg.serverAddr;
      extraFlags = toString (
        cfg.extraFlags
        # OOM defense against the recurring acer-swift hard-hangs:
        # evict pods while the node still has memory to act, and reserve
        # headroom for the OS + k3s itself. The k3s default eviction
        # threshold (100Mi) fires far too late on a 15Gi machine — the
        # kernel OOM-hangs before kubelet reacts. Applies to both roles;
        # lenovo also runs failover pods now.
        ++ [
          "--kubelet-arg=eviction-hard=memory.available<500Mi"
          "--kubelet-arg=eviction-soft=memory.available<1Gi"
          "--kubelet-arg=eviction-soft-grace-period=memory.available=60s"
          "--kubelet-arg=system-reserved=memory=1Gi"
        ]
        ++ optionals (cfg.role == "server") (
          [
            # 600 (k3s default): the admin kubeconfig is cluster-admin; 644 left
            # it world-readable on the desktop control-plane for months. The
            # interactive user gets a 0600 owned COPY via activation (server.nix).
            "--write-kubeconfig-mode=600"
            "--secrets-encryption"
          ]
          ++ (
            if cfg.cni == "cilium" then [
              # Cilium becomes the sole CNI: disable bundled flannel, the embedded
              # network-policy controller, and kube-proxy so Cilium's eBPF datapath
              # (kube-proxy replacement + native NetworkPolicy) can take over.
              #
              # --disable-kube-proxy is SERVER-ONLY — the agent binary rejects it
              # ("flag provided but not defined") and fatals. It is inside this
              # server-only branch for that reason; kube-proxy is off cluster-wide.
              "--flannel-backend=none"
              "--disable-network-policy"
              "--disable-kube-proxy"
            ] else [
              "--flannel-backend=${cfg.flannel.backend}"
            ]
          )
        )
        ++ optionals (cfg.role == "server" && cfg.taintControlPlane) [
          "--node-taint=node-role.kubernetes.io/control-plane:NoSchedule"
        ]
        ++ optionals (cfg.role == "server") (map (c: "--disable=${c}") cfg.disableComponents)
      );
    };

    # During switch, network services can restart before k3s. Wait for a
    # default route so k3s doesn't fail fast with "no default routes found".
    systemd.services.k3s = {
      serviceConfig.ExecStartPre = [
        "${pkgs.bash}/bin/bash -euc 'for i in {1..60}; do if ${pkgs.iproute2}/bin/ip route show default | ${pkgs.gnugrep}/bin/grep -q \"^default\"; then exit 0; fi; sleep 1; done; echo \"k3s: no default route after waiting 60s\" >&2; exit 1'"
      ];
    };

    environment.systemPackages = with pkgs; [
      kubectl
      kubernetes-helm
      k9s
    ];

    boot.kernelModules = [ "br_netfilter" "overlay" ];

    boot.kernel.sysctl = {
      "net.bridge.bridge-nf-call-iptables" = 1;
      "net.bridge.bridge-nf-call-ip6tables" = 1;
      "net.ipv4.ip_forward" = 1;
    };

    networking.firewall = {
      # Cilium owns pod connectivity on its own datapath interfaces. The NixOS
      # host firewall must NOT filter traffic on them, or host<->pod packets
      # (e.g. kubelet liveness/readiness probes) are dropped and every pod flaps.
      # Flannel got this implicitly via k3s' own rules; Cilium needs it explicit.
      trustedInterfaces = optionals (cfg.cni == "cilium") [
        "cilium_host"
        "cilium_net"
        "cilium_vxlan"
        "cilium_health"
        "lxc+"
      ];
      allowedTCPPorts = [
        # Cluster ingress. Moved here from modules/core/network.nix so they are
        # only opened on hosts that actually take part in the k3s data path;
        # a desktop-only machine no longer exposes them.
        80    # HTTP  (ingress / ACME http-01)
        443   # HTTPS (ingress)
        8080  # Alternative HTTP (ingress)
        10250 # Kubelet API
      ]
        ++ optionals (cfg.cni == "cilium") [
          4240 # Cilium agent health check (cilium-health, node-to-node)
          4244 # Hubble server on the agent (Hubble Relay connects here)
          9962 # Cilium agent Prometheus metrics
          9963 # Cilium operator Prometheus metrics
          9964 # Cilium Envoy proxy Prometheus metrics
          9965 # Hubble Prometheus metrics
        ];
      # VXLAN tunnel: flannel uses 8472 when its backend is vxlan; Cilium's
      # default tunnel mode also uses 8472. Open it for either.
      allowedUDPPorts =
        optionals (cfg.cni == "flannel" && cfg.flannel.backend == "vxlan") [ 8472 ]
        ++ optionals (cfg.cni == "cilium") [ 8472 ];
    };
  };
}
