{ lib, pkgs, ... }:
let
  vars = import ./variables.nix;
in
{
  imports = [
    ./hardware-configuration.nix

    ../../modules/hardware/video/${vars.videoDriver}.nix

    # Default boot mode.
    ../../modules/specialisations/desktop.nix

    # Required for Cilium: stock k3s containerd on the server never initializes
    # the Cilium plugin ("cni plugin not initialized"). This gives it a v3-format
    # CNI section with explicit bin/conf dirs, and registers crun/gvisor.
    ../../modules/homelab/k3s/containerd-crun.nix
  ];

  sam.profile = vars;
  sam.hostSecrets.enable = true;

  # The hyprland module sets defaultSession with mkDefault, so the bare
  # assignment below wins. SDDM's remembered Last.Session in
  # /var/lib/sddm/state.conf still beats DefaultSession in the greeter, so this
  # entry needs one manual pick of niri before it sticks. Waybar is still the
  # Hyprland bar and its workspaces module renders empty under niri.
  specialisation.niri.configuration = {
    programs.niri.enable = true;
    services.displayManager.defaultSession = "niri";

    # X11 clients under niri need an external Xwayland shim; the nixpkgs niri
    # module does not install one.
    environment.systemPackages = [ pkgs.xwayland-satellite ];
  };

  # Rebuilds here are manual and precede the push other hosts auto-upgrade from.
  system.autoUpgrade.enable = lib.mkForce false;

  homelab.flux = {
    enable = true;
    gitUrl = "ssh://git@github.com/sammasak/homelab-gitops";
    gitBranch = "main";
    gitPath = "clusters/homelab";
  };

  homelab.k3s.taintControlPlane = true;

  # Drops bundled flannel, kube-proxy and the network-policy controller so
  # Cilium's eBPF datapath takes over.
  homelab.k3s.cni = "cilium";

  # ThinkPad-class laptop: thinkfan + thermald with a less heat-prone curve.
  sam.thermal = {
    platform = "thinkpad";
    profile = "quiet";
  };

  homelab.dns = {
    enable = true;
    tls = {
      enable = true;
      domain = "dns.sammasak.dev";
      dohPort = 443;
    };
    rewrites = [
      # Wildcard to the Traefik MetalLB IP. Per-service records from External-DNS
      # are written as AdGuard *filtering rules*, not rewrites, and persist
      # because mutableSettings is true — so they never collide with these.
      { domain = "*.sammasak.dev"; answer = "192.168.10.203"; }
      { domain = "sammasak.dev"; answer = "192.168.10.203"; }
      { domain = "dns.sammasak.dev"; answer = "192.168.10.154"; }  # AdGuard Home on host
    ];
  };

  homelab.acme = {
    enable = true;
    dnsDomain = "dns.sammasak.dev";
  };

  # Runs outside k8s so paging survives a worker outage. Mobile subscribes to
  # the LAN URL below, or to the same port on the Tailscale IP.
  homelab.ntfy = {
    enable = true;
    baseUrl = "http://192.168.10.154:2586";
  };

  homelab.clusterWatchdog.enable = true;

  # Grants non-interactive control-plane deploy — a deliberate trust choice.
  # See vault: homelab/decisions/ADR-024-nixos-rebuild-trigger-security-model.md
  homelab.nixosRebuildTrigger.enable = true;
}
