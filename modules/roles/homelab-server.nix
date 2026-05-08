# Homelab k3s server role
# Use this role for control plane nodes
{ lib, pkgs, config, ... }:
let
  username = config.sam.profile.username;
in
{
  imports = [
    ./base.nix
    ../homelab/k3s/server.nix
    ../homelab/adguardhome.nix
    ../homelab/acme.nix
    ../homelab/tailscale.nix
  ];

  # Homelab improvement loop: all systemd user services, timers, and path units
  # that run the kanban board agents. Managed here so they survive nixos-rebuild.
  home-manager.users.${username}.imports = [
    ../homelab/improvement-loop.nix
  ];

  # claude-ctl CLI tool for managing agents
  environment.systemPackages = [ pkgs.claude-ctl ];

  # Server role defaults
  homelab.k3s = {
    enable = true;
    role = "server";
  };

  # Tailscale subnet router for control plane node
  homelab.tailscale.enable = true;

  # Keep server always on - never sleep on lid close (override laptop defaults)
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
