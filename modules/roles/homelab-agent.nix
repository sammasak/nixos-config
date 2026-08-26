# Homelab k3s agent role
# Use this role for worker nodes
{ lib, pkgs, ... }:
{
  imports = [
    ./base.nix
    ../homelab/k3s/agent.nix
  ];

  # claude-ctl CLI tool for managing agents
  environment.systemPackages = [ pkgs.claude-ctl ];

  # Agent role defaults
  homelab.k3s = {
    enable = true;
    role = "agent";
  };

  # Keep worker always on - never sleep on lid close (override laptop defaults)
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
