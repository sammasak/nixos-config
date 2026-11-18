# The fleet's one night (sam.fleet.night, modules/core/fleet.nix), two behaviours. A host with a power window
# (sam.fleet.hosts.<name>.power) is off: an always-on waker sends it its Wake-on-LAN packet at `wake`, and the host
# arms Wake-on-LAN on its `interface` and powers itself off at `off`. No weekend wake fires, so a Mon-Fri window
# stays off from Fri `off` to Mon `wake`. A quiet host (sam.fleet.hosts.<name>.quiet: fans that stay on) runs
# throttled every night, weekends included: scripts/night-quiet.sh sets intel_pstate from the clock at boot, at a
# deploy that changes it, and at both edges.
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
  entry =
    hosts.${host} or {
      power = null;
      quiet = null;
    };
  own = entry.power;
  quiet = entry.quiet;
  inherit (config.sam.fleet) night;
  both = lib.attrNames (lib.filterAttrs (_: h: h.power != null && h.quiet != null) hosts);
  nightQuiet = "${pkgs.bash}/bin/bash ${../../scripts/night-quiet.sh} ${night.start} ${night.end} ${
    toString (if quiet == null then 100 else quiet.maxPerfPct)
  }";
  awake = lib.filter (n: !hosts.${n}.sleeps) (lib.attrNames windowed);
  prefixes = map prefix (lib.attrNames windowed);
in
{
  options.sam.powerSchedule = {
    waker.enable = mkEnableOption "sending every host with a fleet power window its Wake-on-LAN packet (enable on an always-on host)";
    # on by the fleet fact; off only for a configuration that borrows a window host's name, e.g. a VM test
    poweroff.enable = lib.mkOption {
      type = lib.types.bool;
      default = own != null;
      description = "This host's scheduled poweroff and Wake-on-LAN unit from its fleet power window.";
    };
    # on by the fleet fact, like poweroff
    quiet.enable = lib.mkOption {
      type = lib.types.bool;
      default = quiet != null;
      description = "This host's night throttle (scripts/night-quiet.sh) from its fleet quiet entry.";
    };
  };

  config = mkMerge [
    {
      # not an assertion: the VM tests that borrow msi's name set it off and must still build
      warnings =
        lib.optional (own != null && !cfg.poweroff.enable)
          "${host} has a fleet power window (modules/core/fleet.nix) but sam.powerSchedule.poweroff.enable is off: it will not power itself off at ${own.off}. Only a VM test that borrows its name should do that.";
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
          assertion = both == [ ];
          message = "modules/core/fleet.nix: ${toString both} has both a power window and a quiet night; a host is either off or throttled through the night.";
        }
        {
          # the Pis are fanless and run no intel_pstate: neither behaviour is theirs
          assertion = !pkgs.stdenv.hostPlatform.isAarch || (own == null && quiet == null);
          message = "modules/core/fleet.nix: ${host} is an ARM board, fanless, with no Wake-on-LAN NIC or intel_pstate: it declares neither a power window nor a quiet night.";
        }
        {
          assertion =
            quiet == null
            || (
              quiet.driver == "intel_pstate"
              && pkgs.stdenv.hostPlatform.isx86_64
              && !lib.elem "intel_pstate=disable" config.boot.kernelParams
            );
          message = "${host} is quiet through the night with driver intel_pstate (modules/core/fleet.nix), so it must be an x86_64 Intel host that keeps intel_pstate (no intel_pstate=disable in boot.kernelParams); scripts/night-quiet.sh writes its no_turbo and max_perf_pct.";
        }
        {
          assertion = lib.length prefixes == lib.length (lib.unique prefixes);
          message = "modules/core/power-schedule.nix: two power-window hosts share the unit prefix of their names (${toString prefixes}).";
        }
      ]
      ++ lib.optional (own != null && cfg.poweroff.enable) {
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

    (mkIf (quiet != null && cfg.quiet.enable) {
      # the state at boot, and again at a deploy that changes the night or the percentage (the unit changes with them)
      systemd.services.night-quiet = {
        description = "CPU for the time of day: throttled through the fleet's night";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = nightQuiet;
        };
      };
      # the edges; no catch-up, as night-quiet already set the state from the clock at boot
      systemd.services.night-quiet-edge = {
        description = "CPU for the time of day, at the night's start and end";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = nightQuiet;
        };
      };
      systemd.timers.night-quiet-edge = {
        description = "The fleet's night starting and ending";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = [
            "*-*-* ${night.start}:00"
            "*-*-* ${night.end}:00"
          ];
          Persistent = false;
        };
      };
    })

    (mkIf (own != null && cfg.poweroff.enable) {
      networking.interfaces.${own.interface}.wakeOnLan.enable = true;
      systemd.services."wol-${own.interface}" = {
        description = "Enable Wake on LAN for ${own.interface}";
        after = [ "network-addresses-${own.interface}.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.ethtool}/sbin/ethtool -s ${own.interface} wol g";
        };
      };
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
