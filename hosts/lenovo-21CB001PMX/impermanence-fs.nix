# STAGED, NOT IMPORTED: activation needs the physical migration runbook
# (rescue media + /persist disk carve + on-site reboot, plan §5.3 step 5).
# hardware-configuration.nix stays untouched by design (generated file,
# fileSystems."/boot" unaffected); its fileSystems."/" is only superseded
# once this file is imported. /persist's device is a Phase A placeholder —
# the runbook's rescue-media disk carve (Phase B) creates the real UUID,
# substituted in Phase C before import.
{ lib, ... }:
{
  fileSystems."/" = {
    device = "none";
    fsType = "tmpfs";
    options = [ "size=8G" "mode=0755" ]; # ~50% of lenovo's 15Gi RAM
  };

  fileSystems."/nix-holder" = {
    device = "/dev/disk/by-uuid/503273ca-1377-4c75-8b2c-ff70c4d728f6";
    fsType = "ext4";
    neededForBoot = true;
  };

  fileSystems."/nix" = {
    device = "/nix-holder/nix";
    options = [ "bind" ];
    neededForBoot = true;
  };

  fileSystems."/persist" = {
    device = "/dev/disk/by-uuid/00000000-0000-0000-0000-000000000000"; # PLACEHOLDER, see Phase C
    fsType = "ext4";
    neededForBoot = true;
  };

  # Capped: boot.tmp's own 50%-of-RAM default would add a second ~7.7G budget
  # alongside root's own 8G tmpfs above.
  boot.tmp.useTmpfs = true;
  boot.tmp.tmpfsSize = "2G";

  # Migration-window-only, until step 8/9's cold-reboot and soak checks pass:
  # homelab-server.nix's watchdog would otherwise force-reboot a hung boot.
  systemd.settings.Manager = {
    RuntimeWatchdogSec = lib.mkForce "0";
    RebootWatchdogSec = lib.mkForce "0";
  };
}
