# Always-on semantics for homelab nodes: never sleep, ignore the lid,
# power button still works. Imported by the homelab-agent and
# homelab-server roles — NOT by base (laptops in non-homelab roles keep
# normal power behaviour).
{ lib, ... }:
{
  services.logind.settings.Login = {
    HandleLidSwitch = lib.mkForce "ignore";
    HandleLidSwitchExternalPower = lib.mkForce "ignore";
    HandleLidSwitchDocked = lib.mkForce "ignore";
    IdleAction = lib.mkForce "ignore";
    HandlePowerKey = lib.mkForce "poweroff";
  };

  systemd.targets = {
    sleep.enable = false;
    suspend.enable = false;
    hibernate.enable = false;
    hybrid-sleep.enable = false;
  };
}
