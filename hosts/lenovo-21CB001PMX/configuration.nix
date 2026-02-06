# Host configuration for lenovo-21CB001PMX
{ lib, host, ... }:
let
  vars = import ./variables.nix;
  roles = vars.roles or [ "base" "desktop" "laptop" ];
in
{
  imports = [
    ./hardware-configuration.nix

    # Hardware
    ../../modules/hardware/video/${vars.videoDriver}.nix
  ]
  ++ lib.optionals (builtins.elem "base" roles) [ ../../modules/roles/base.nix ]
  ++ lib.optionals (builtins.elem "desktop" roles) [ ../../modules/roles/desktop.nix ]
  ++ lib.optionals (builtins.elem "laptop" roles) [ ../../modules/roles/laptop.nix ]
  ++ lib.optionals (builtins.elem "homelab-server" roles) [ ../../modules/roles/homelab-server.nix ]
  ++ lib.optionals (builtins.elem "homelab-agent" roles) [ ../../modules/roles/homelab-agent.nix ];

  # Flux
  homelab.flux = {
    enable = true;
    gitUrl = "ssh://git@github.com/sammasak/homelab-gitops";
    gitBranch = "main";
    gitPath = "clusters/homelab";
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
