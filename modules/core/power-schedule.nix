# Work-hours power windows for the hosts whose fleet entry declares one (sam.fleet.hosts.<name>.power,
# modules/core/fleet.nix): an always-on waker sends each its Wake-on-LAN packet at `wake`, and the host
# powers itself off at `off`. No weekend wake fires, so a Mon-Fri window stays off from Fri `off` to Mon `wake`.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkEnableOption mkIf mkMerge;
  cfg = config.sam.powerSchedule;
  hosts = config.sam.fleet.hosts;
  host = config.networking.hostName;
  windowed = lib.filterAttrs (_: h: h.power != null) hosts;
  # msi-ms7758 -> msi: the unit names predate the fleet fact and stay as they were
  prefix = name: lib.head (lib.splitString "-" name);
  own = (hosts.${host} or { power = null; }).power;
  awake = lib.filter (n: !hosts.${n}.sleeps) (lib.attrNames windowed);
  prefixes = map prefix (lib.attrNames windowed);
in
{
  options.sam.powerSchedule.waker.enable =
    mkEnableOption "sending every host with a fleet power window its Wake-on-LAN packet (enable on an always-on host)";

  config = mkMerge [
    {
      assertions = [
        {
          assertion = awake == [ ];
          message = "modules/core/fleet.nix: ${toString awake} has a power window, so it is off by plan: set sleeps = true on its entry.";
        }
        {
          assertion = !cfg.waker.enable || !(hosts.${host} or { sleeps = false; }).sleeps;
          message = "sam.powerSchedule.waker runs only on an always-on host; ${host} sleeps (modules/core/fleet.nix), so it would miss the wakes.";
        }
        {
          assertion = lib.length prefixes == lib.length (lib.unique prefixes);
          message = "modules/core/power-schedule.nix: two power-window hosts share the unit prefix of their names (${toString prefixes}).";
        }
      ]
      ++ lib.optional (own != null) {
        assertion =
          config.networking.interfaces.${own.interface}.wakeOnLan.enable or false
          && config.systemd.services ? "wol-${own.interface}";
        message = "${host} has a power window on ${own.interface} (modules/core/fleet.nix), so it needs networking.interfaces.${own.interface}.wakeOnLan.enable and its wol-${own.interface} unit, or no wake reaches it.";
      };
    }

    (mkIf cfg.waker.enable {
      systemd.services = lib.mapAttrs' (
        name: h:
        lib.nameValuePair "${prefix name}-wake" {
          description = "Wake ${name} via Wake-on-LAN";
          # WoL is best-effort: a failed send must not leave a failed unit around.
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.wakeonlan}/bin/wakeonlan ${h.power.mac}";
          };
        }
      ) windowed;
      systemd.timers = lib.mapAttrs' (
        name: h:
        lib.nameValuePair "${prefix name}-wake" {
          description = "Wake ${name} on the work-hours schedule";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = h.power.wake;
            # Do NOT catch up a missed wake (e.g. a weekend boot of the control
            # plane) — only wake at the real scheduled tick.
            Persistent = false;
          };
        }
      ) windowed;
    })

    (mkIf (own != null) {
      systemd.services."${prefix host}-scheduled-shutdown" = {
        description = "Scheduled poweroff of ${prefix host}";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.systemd}/bin/systemctl poweroff";
        };
      };
      systemd.timers."${prefix host}-scheduled-shutdown" = {
        description = "Scheduled work-hours shutdown of ${prefix host}";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = own.off;
          # No catch-up: if the host was off at `off` it is already where we want it.
          Persistent = false;
        };
      };
    })
  ];
}
