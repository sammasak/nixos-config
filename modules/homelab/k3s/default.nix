# Common k3s configuration shared between server and agent
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    optionals
    types
    ;
  cfg = config.homelab.k3s;
  quantity = types.strMatching "[0-9]+(Ki|Mi|Gi)";
in
{
  imports = [
    ../sops.nix
    ./containerd-crun.nix
  ];

  options.homelab.k3s = {
    enable = mkEnableOption "k3s Kubernetes";

    role = mkOption {
      type = types.enum [
        "server"
        "agent"
      ];
      description = "Node role in the cluster";
    };

    serverAddr = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Address of the k3s server (required for agents)";
    };

    extraFlags = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Additional flags to pass to k3s";
    };

    memory = {
      systemReserved = mkOption {
        type = quantity;
        default = "1Gi";
        description = "kubelet system-reserved memory (headroom for the OS + k3s itself).";
      };
      evictionHard = mkOption {
        type = quantity;
        default = "500Mi";
        description = "kubelet hard-eviction threshold on memory.available.";
      };
      evictionSoft = mkOption {
        type = quantity;
        default = "1Gi";
        description = "kubelet soft-eviction threshold on memory.available (60s grace).";
      };
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
        assertion = cfg.role == "server" || cfg.serverAddr != null;
        message = "homelab.k3s.serverAddr must be set for agent nodes";
      }
      {
        assertion =
          !lib.any (
            f: lib.hasInfix "shutdownGracePeriod" f || lib.hasInfix "shutdown-grace-period" f
          ) cfg.extraFlags;
        message = "homelab.k3s.extraFlags: shutdownGracePeriod is a kubelet config-file field, not a CLI flag; kubelet exits on the unknown flag and the node crashloops";
      }
    ];

    services.k3s = {
      enable = true;
      role = cfg.role;
      tokenFile = config.sops.secrets."k3s/cluster_token".path;
      serverAddr = mkIf (cfg.role == "agent") cfg.serverAddr;
      extraFlags = toString (
        cfg.extraFlags
        # OOM defense against the recurring acer-swift hard-hangs:
        # evict pods while the node still has memory to act, and reserve
        # headroom for the OS + k3s itself. The k3s default eviction
        # threshold (100Mi) fires far too late on a 15Gi machine — the
        # kernel OOM-hangs before kubelet reacts. Applies to both roles.
        ++ [
          "--kubelet-arg=eviction-hard=memory.available<${cfg.memory.evictionHard}"
          "--kubelet-arg=eviction-soft=memory.available<${cfg.memory.evictionSoft}"
          "--kubelet-arg=eviction-soft-grace-period=memory.available=60s"
          "--kubelet-arg=system-reserved=memory=${cfg.memory.systemReserved}"
        ]
        ++ optionals (cfg.role == "server") [
          # 600 (k3s default): the admin kubeconfig is cluster-admin; 644 left
          # it world-readable on the desktop control-plane for months. The
          # interactive user gets a 0600 owned COPY via activation (server.nix).
          "--write-kubeconfig-mode=600"
          "--secrets-encryption"
          # Cilium (deployed by Flux) is the sole CNI and replaces kube-proxy.
          # Server-only: the agent binary rejects --disable-kube-proxy
          # ("flag provided but not defined") and fatals.
          "--flannel-backend=none"
          "--disable-network-policy"
          "--disable-kube-proxy"
        ]
        ++ optionals (cfg.role == "server" && cfg.taintControlPlane) [
          "--node-taint=node-role.kubernetes.io/control-plane:NoSchedule"
        ]
        # local-storage is replaced by a resource-limited copy (server.nix's k3s-manifests).
        # metrics-server stays off: nothing depends on metrics.k8s.io; autoscaling is
        # all KEDA (external.metrics.k8s.io) and no HPA uses Resource metrics.
        ++ optionals (cfg.role == "server") [
          "--disable=traefik"
          "--disable=servicelb"
          "--disable=local-storage"
          "--disable=metrics-server"
        ]
      );
    };

    # During switch, network services can restart before k3s. Wait for a
    # default route so k3s doesn't fail fast with "no default routes found".
    systemd.services.k3s = {
      serviceConfig.Slice = "homelab.slice";
      serviceConfig.ExecStartPre = [
        "${pkgs.bash}/bin/bash -euc 'for i in {1..60}; do if ${pkgs.iproute2}/bin/ip route show default | ${pkgs.gnugrep}/bin/grep -q \"^default\"; then exit 0; fi; sleep 1; done; echo \"k3s: no default route after waiting 60s\" >&2; exit 1'"
      ];
    };

    # Keep the desktop and coding tools responsive when the node is also
    # running containers. Child processes, including k3s's bundled containerd,
    # inherit this slice.
    systemd.slices.homelab = {
      description = "Low-priority homelab workloads";
      sliceConfig = {
        CPUWeight = 50;
        IOWeight = 50;
      };
    };

    environment.systemPackages = with pkgs; [
      kubectl
      kubernetes-helm
      k9s
    ];

    boot.kernelModules = [
      "br_netfilter"
      "overlay"
    ];

    boot.kernel.sysctl = {
      "net.bridge.bridge-nf-call-iptables" = 1;
      "net.bridge.bridge-nf-call-ip6tables" = 1;
      "net.ipv4.ip_forward" = 1;
    };

    networking.firewall = {
      # Cilium owns pod connectivity on its own datapath interfaces. The NixOS
      # host firewall must NOT filter traffic on them, or host<->pod packets
      # (e.g. kubelet liveness/readiness probes) are dropped and every pod flaps.
      trustedInterfaces = [
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
        80 # HTTP  (ingress / ACME http-01)
        443 # HTTPS (ingress)
        8080 # Alternative HTTP (ingress)
        10250 # Kubelet API
        4240 # Cilium agent health check (cilium-health, node-to-node)
        4244 # Hubble server on the agent (Hubble Relay connects here)
        9962 # Cilium agent Prometheus metrics
        9963 # Cilium operator Prometheus metrics
        9964 # Cilium Envoy proxy Prometheus metrics
        9965 # Hubble Prometheus metrics
      ];
      allowedUDPPorts = [
        8472 # Cilium VXLAN, its default tunnel mode
      ];
    };
  };
}
