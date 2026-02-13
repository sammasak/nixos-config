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
  ];

  sam.profile = vars;

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
  systemd.services.set-default-power-profile = {
    description = "Set default power profile to balanced";
    after = [ "power-profiles-daemon.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.power-profiles-daemon}/bin/powerprofilesctl set balanced";
    };
  };

  # DNS server with encrypted DNS (DoT/DoH) for sammasak.dev
  homelab.dns = {
    enable = true;
    tls = {
      enable = true;
      domain = "dns.sammasak.dev";
      dohPort = 443;
    };
    rewrites = [
      # Workstation SSH endpoints (generated from homelab-gitops service IPs).
      { domain = "rocket.sammasak.dev"; answer = "192.168.10.208"; }

      { domain = "*.sammasak.dev"; answer = "192.168.10.200"; }  # K8s services via MetalLB
      { domain = "sammasak.dev"; answer = "192.168.10.200"; }
      { domain = "dns.sammasak.dev"; answer = "192.168.10.154"; }  # AdGuard Home on host
    ];
  };

  # ACME certificate management for encrypted DNS
  homelab.acme = {
    enable = true;
    dnsDomain = "dns.sammasak.dev";
  };
}
