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
  ++ lib.optionals (builtins.elem "laptop" roles) [ ../../modules/roles/laptop.nix ];

  # Intel thermal management
  services.thermald.enable = true;
}
