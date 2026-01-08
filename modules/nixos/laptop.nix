{pkgs, ... }:
{
  services.power-profiles-daemon.enable = true;
  services.logind.lidSwitch = "suspend";
} 
