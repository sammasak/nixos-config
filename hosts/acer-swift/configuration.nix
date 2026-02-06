# Host configuration for acer-swift
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

  # Keep laptop always on - never sleep on lid close (override laptop defaults)
  services.logind.settings.Login = {
    HandleLidSwitch = lib.mkForce "ignore";
    HandleLidSwitchExternalPower = lib.mkForce "ignore";
    HandleLidSwitchDocked = lib.mkForce "ignore";
    IdleAction = lib.mkForce "ignore";
    HandlePowerKey = lib.mkForce "poweroff";
  };

  # Disable sleep/hibernate
  systemd.targets = {
    sleep.enable = false;
    suspend.enable = false;
    hibernate.enable = false;
    hybrid-sleep.enable = false;
  };
}
