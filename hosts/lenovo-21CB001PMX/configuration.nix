# Host configuration for lenovo-21CB001PMX
{ lib, pkgs, ... }:
let
  vars = import ./variables.nix;
in
{
  imports = [
    ./hardware-configuration.nix

    # Hardware
    ../../modules/hardware/video/${vars.videoDriver}.nix

    # Desktop mode (default boot)
    ../../modules/specialisations/desktop.nix

    # Custom containerd config (v3-format CNI section with explicit bin/conf dirs).
    # Required for Cilium CNI: stock k3s containerd on the server never initializes
    # the Cilium CNI plugin ("cni plugin not initialized"); acer works because it
    # imports this. Also registers crun/gvisor runtimes (harmless on control-plane).
    ../../modules/homelab/k3s/containerd-crun.nix
  ];

  sam.profile = vars;
  sam.secrets.enable = true;

  # Server specialisation (boot menu option for headless mode)
  specialisation.server.configuration = {
    imports = [ ../../modules/specialisations/server.nix ];
  };

  # Niri trial (boot menu option) — a scrollable-tiling compositor, evaluated
  # side by side with Hyprland. Specialisations inherit the parent config, so
  # this entry keeps the whole default desktop (SDDM, portals, fonts, GUI
  # packages, Home Manager desktop imports) and only adds a second session:
  # SDDM stays the chooser and niri registers its own session, while
  # services.displayManager.defaultSession remains "hyprland".
  #
  # Deliberately minimal — it is a trial, not a rice. Waybar is still the
  # Hyprland bar (its modules-left uses hyprland/workspaces, which renders
  # empty under niri); if niri sticks, swap that module for niri-taskbar or
  # a niri-native bar rather than patching the shared Hyprland waybar config.
  specialisation.niri.configuration = {
    programs.niri.enable = true;

    # X11 clients under niri need an external Xwayland shim; the nixpkgs niri
    # module does not install one.
    environment.systemPackages = [ pkgs.xwayland-satellite ];
  };

  # Lenovo is the source of truth — rebuilds run manually before pushing to the
  # homelab branch. Other hosts pick up changes via system.autoUpgrade from GitHub.
  system.autoUpgrade.enable = lib.mkForce false;

  # Flux
  homelab.flux = {
    enable = true;
    gitUrl = "ssh://git@github.com/sammasak/homelab-gitops";
    gitBranch = "main";
    gitPath = "clusters/homelab";
  };

  # Keep control-plane focused on cluster management.
  homelab.k3s.taintControlPlane = true;

  # Cilium is the cluster CNI: k3s drops bundled flannel, kube-proxy, and the
  # network-policy controller so Cilium's eBPF datapath + Hubble take over.
  homelab.k3s.cni = "cilium";

  # ThinkPad-class laptop: use thinkfan + thermald with a less heat-prone curve.
  hardware.thermal = {
    platform = "thinkpad";
    profile = "quiet";
  };

  # Avoid unnecessary heat from an always-on performance profile.
  # Note: power-profiles-daemon defaults to balanced automatically; explicit setting removed to avoid systemd ordering cycle
  # systemd.services.set-default-power-profile = {
  #   description = "Set default power profile to balanced";
  #   after = [ "power-profiles-daemon.service" "multi-user.target" ];
  #   wantedBy = [ "default.target" ];
  #   serviceConfig = {
  #     Type = "oneshot";
  #     ExecStart = "${pkgs.power-profiles-daemon}/bin/powerprofilesctl set balanced";
  #   };
  # };

  # DNS server with encrypted DNS (DoT/DoH) for sammasak.dev
  homelab.dns = {
    enable = true;
    tls = {
      enable = true;
      domain = "dns.sammasak.dev";
      dohPort = 443;
    };
    rewrites = [
      # Wildcard for all K8s ingress-based services via Traefik MetalLB IP.
      # Per-service records published by External-DNS running in the k3s cluster
      # are written as AdGuard filtering rules (not rewrites). With
      # mutableSettings=true, those filtering rules persist.
      { domain = "*.sammasak.dev"; answer = "192.168.10.203"; }
      { domain = "sammasak.dev"; answer = "192.168.10.203"; }
      { domain = "dns.sammasak.dev"; answer = "192.168.10.154"; }  # AdGuard Home on host
    ];
  };

  # ACME certificate management for encrypted DNS
  homelab.acme = {
    enable = true;
    dnsDomain = "dns.sammasak.dev";
  };

  # ntfy push notification server — runs outside k8s, survives worker outages.
  # Subscribe on mobile: http://192.168.10.154:2586 (LAN) or via Tailscale IP.
  homelab.ntfy = {
    enable = true;
    baseUrl = "http://192.168.10.154:2586";
  };

  # Cluster health watchdog — checks node readiness + monitoring stack every 10 min.
  homelab.clusterWatchdog.enable = true;

  # Non-interactive, health-gated nixos-rebuild trigger for the homelab board
  # worker. Rebuilds from a PINNED git SHA fetched fresh from
  # github:sammasak/nixos-config (NOT the agent-writable local clone), under a
  # deploy lock, with k3s/sshd/DNS health checks and automatic rollback.
  # Enabling this grants non-interactive control-plane deploy - a deliberate
  # trust choice. See modules/homelab/nixos-rebuild-trigger.nix for the full
  # security model and invocation instructions.
  homelab.nixosRebuildTrigger.enable = true;
}
