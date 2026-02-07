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
  ++ lib.optionals (builtins.elem "laptop" roles) [ ../../modules/roles/laptop.nix ]
  ++ lib.optionals (builtins.elem "homelab-agent" roles) [ ../../modules/roles/homelab-agent.nix ];

  # k3s agent configuration
  homelab.k3s.serverAddr = "https://192.168.10.154:6443";  # k3s server on lenovo-21CB001PMX
  homelab.k3s.extraFlags = [
    "--node-label=node-pool=workers"
  ];

  # Acer laptop: use generic thermal policy (BIOS/EC fan tables + thermald).
  hardware.thermal = {
    platform = "generic";
    profile = "balanced";
  };

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
