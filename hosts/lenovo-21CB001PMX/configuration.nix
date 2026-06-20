# Host configuration for lenovo-21CB001PMX
{ pkgs, ... }:
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
  ];

  sam.profile = vars;
  sam.secrets.enable = true;

  # Server specialisation (boot menu option for headless mode)
  specialisation.server.configuration = {
    imports = [ ../../modules/specialisations/server.nix ];
  };

  # Flux
  homelab.flux = {
    enable = true;
    gitUrl = "ssh://git@github.com/sammasak/homelab-gitops";
    gitBranch = "main";
    gitPath = "clusters/homelab";
  };

  # Keep control-plane focused on cluster management.
  homelab.k3s.taintControlPlane = true;

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
      # Wildcard for all K8s ingress-based services via MetalLB ingress IP.
      # Workstation SSH endpoints (openfang-central, rocket, etc.) are managed
      # by External-DNS running in the k3s cluster and written as AdGuard filtering
      # rules (not rewrites). With mutableSettings=true, those filtering rules persist.
      { domain = "*.sammasak.dev"; answer = "192.168.10.200"; }
      { domain = "sammasak.dev"; answer = "192.168.10.200"; }
      { domain = "dns.sammasak.dev"; answer = "192.168.10.154"; }  # AdGuard Home on host
    ];
  };

  # ACME certificate management for encrypted DNS
  homelab.acme = {
    enable = true;
    dnsDomain = "dns.sammasak.dev";
  };

  # Non-interactive, health-gated nixos-rebuild trigger for the homelab board
  # worker. Rebuilds from a PINNED git SHA fetched fresh from
  # github:sammasak/nixos-config (NOT the agent-writable local clone), under a
  # deploy lock, with k3s/sshd/DNS health checks and automatic rollback.
  # Enabling this grants non-interactive control-plane deploy - a deliberate
  # trust choice. See modules/homelab/nixos-rebuild-trigger.nix for the full
  # security model and invocation instructions.
  homelab.nixosRebuildTrigger.enable = true;
}
