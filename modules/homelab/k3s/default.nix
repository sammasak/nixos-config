# Common k3s configuration shared between server and agent
{ config, lib, pkgs, ... }:

with lib;

let
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
      default = "/run/secrets/k3s-cluster-token";
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
        description = "Flannel backend for pod networking";
      };
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
    # Enable homelab secrets for cluster token
    homelab.secrets.enable = true;

    # Ensure token file is specified
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
        ++ optionals (cfg.role == "server") [
          "--flannel-backend=${cfg.flannel.backend}"
          "--write-kubeconfig-mode=644"
        ]
        ++ optionals (cfg.role == "server" && cfg.taintControlPlane) [
          "--node-taint=node-role.kubernetes.io/control-plane:NoSchedule"
        ]
        ++ optionals (cfg.role == "server") (map (c: "--disable=${c}") cfg.disableComponents)
      );
    };

    # Common packages for all k3s nodes
    environment.systemPackages = with pkgs; [
      kubectl
      kubernetes-helm
      k9s
    ];

    # Ensure required kernel modules
    boot.kernelModules = [ "br_netfilter" "overlay" ];

    # Required sysctl settings for Kubernetes
    boot.kernel.sysctl = {
      "net.bridge.bridge-nf-call-iptables" = 1;
      "net.bridge.bridge-nf-call-ip6tables" = 1;
      "net.ipv4.ip_forward" = 1;
    };

    # Common firewall rules
    networking.firewall = {
      allowedTCPPorts = [ 10250 ]; # Kubelet API
      allowedUDPPorts = mkIf (cfg.flannel.backend == "vxlan") [ 8472 ]; # Flannel VXLAN
    };
  };
}
