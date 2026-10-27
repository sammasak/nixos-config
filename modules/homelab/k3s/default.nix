# Common k3s configuration shared between server and agent
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption optionals optionalString types;
  inherit (import ../../../lib/firewall.nix lib) mkDualBackendFirewall;
  cfg = config.homelab.k3s;
  quantity = types.strMatching "[0-9]+(Ki|Mi|Gi)";

  isCilium = cfg.cni == "cilium";
  lanCidr = config.sam.profile.lanCidr;
  clusterSources = [
    lanCidr # node LAN addrs + admin workstations
    "10.42.0.0/16" # k3s pod CIDR (Cilium native-routing keeps the pod source IP)
    "10.43.0.0/16" # k3s service CIDR (ClusterIP hairpin)
  ];
  # tailscale0 only exists on hosts running a tailscale client (acer runs none),
  # where it is already a trustedInterface; the accept is inert otherwise and
  # belt-and-braces there, matching the control-plane API rules in server.nix.
  lanInterfaces = [ "tailscale0" ];

  backend = config.networking.firewall.backend;

  # North-south ingress: LAN clients (and remote admins over the tailnet) only.
  # 8080 has no proven host listener here — lenovo's llm-gateway port-forward
  # binds 127.0.0.1 and the pi reaches 8080 via the in-cluster ClusterIP, not
  # this host port — but the ingress path (managed out-of-band in Flux) may bind
  # it, so it stays opened, scoped to the LAN rather than any source.
  ingressRules = mkDualBackendFirewall {
    nftComment = "k3s cluster ingress (HTTP/HTTPS): LAN clients and tailnet only.";
    ports = [
      80 # HTTP  (ingress / ACME http-01)
      443 # HTTPS (ingress)
      8080 # Alternative HTTP (ingress)
    ];
    sources = [ lanCidr ];
    interfaces = lanInterfaces;
    inherit backend;
  };

  # Kubelet API and Cilium's node-to-node / metrics ports: reachable from LAN
  # nodes, the pod and service CIDRs, and tailnet admins — never any source.
  clusterRules = mkDualBackendFirewall {
    nftComment = "k3s kubelet + Cilium health/metrics: LAN, cluster networks and tailnet only.";
    ports = [
      10250 # Kubelet API (liveness/readiness probes, metrics)
    ]
    ++ optionals isCilium [
      4240 # Cilium agent health check (cilium-health, node-to-node)
      4244 # Hubble server on the agent (Hubble Relay connects here)
      9962 # Cilium agent Prometheus metrics
      9963 # Cilium operator Prometheus metrics
      9964 # Cilium Envoy proxy Prometheus metrics
      9965 # Hubble Prometheus metrics
    ];
    sources = clusterSources;
    interfaces = lanInterfaces;
    inherit backend;
  };

  # Cilium's default tunnel mode is VXLAN on 8472; flannel's host-gw needs no
  # tunnel. Node-to-node only, so scope to the LAN subnet.
  vxlanRules = mkDualBackendFirewall {
    nftComment = "k3s VXLAN overlay (8472/udp): node LAN addresses only.";
    ports = [ ];
    sources = [ lanCidr ];
    interfaces = [ ];
    udpPorts = [ 8472 ];
    inherit backend;
  };

  needsVxlan = isCilium;
in
{
  imports = [ ../sops.nix ./containerd-crun.nix ];

  options.homelab.k3s = {
    enable = mkEnableOption "k3s Kubernetes";

    role = mkOption {
      type = types.enum [ "server" "agent" ];
      description = "Node role in the cluster";
    };

    serverAddr = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Address of the k3s server (required for agents)";
    };

    tokenFile = mkOption {
      type = types.path;
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
        # kernel OOM-hangs before kubelet reacts. Applies to both roles.
        ++ [
          "--kubelet-arg=eviction-hard=memory.available<${cfg.memory.evictionHard}"
          "--kubelet-arg=eviction-soft=memory.available<${cfg.memory.evictionSoft}"
          "--kubelet-arg=eviction-soft-grace-period=memory.available=60s"
          "--kubelet-arg=system-reserved=memory=${cfg.memory.systemReserved}"
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
              # Server-only: the agent binary rejects --disable-kube-proxy
              # ("flag provided but not defined") and fatals.
              "--flannel-backend=none"
              "--disable-network-policy"
              "--disable-kube-proxy"
            ] else [
              "--flannel-backend=host-gw"
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
      # Scoped accepts replace the former any-source allowedTCPPorts/UDPPorts.
      # These ports are cluster data-path, not public services, so they stay out
      # of allowedTCPPorts (which accepts from any routable source). See the rule
      # groups in `let` above for the source scoping per port.
      extraInputRules =
        ingressRules.extraInputRules
        + clusterRules.extraInputRules
        + optionalString needsVxlan vxlanRules.extraInputRules;
      extraCommands =
        ingressRules.extraCommands
        + clusterRules.extraCommands
        + optionalString needsVxlan vxlanRules.extraCommands;
    };
  };
}
