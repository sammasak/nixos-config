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

  # Intel thermal management
  services.thermald.enable = true;


  # Flux
  homelab.flux = {
    enable = true;
    gitUrl = "ssh://git@github.com/sammasak/homelab-gitops";
    gitBranch = "main";
    gitPath = "clusters/homelab";
  };
}
