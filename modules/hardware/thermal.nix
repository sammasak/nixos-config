# Lives under `sam.thermal`, not `hardware.thermal`: `hardware.*` is upstream
# NixOS territory, and squatting in it makes a local option indistinguishable
# from a nixpkgs one — and collides outright the day upstream adds that name.
{
  config,
  lib,
  ...
}:

let
  cfg = config.sam.thermal;
in
{
  options.sam.thermal = {
    platform = lib.mkOption {
      type = lib.types.enum [
        "thinkpad"
        "generic"
      ];
      default = "generic";
      description = "Hardware platform for fan control";
    };

    energyPerformancePreference = lib.mkOption {
      type = lib.types.enum [
        "default"
        "performance"
        "balance_performance"
        "balance_power"
        "power"
      ];
      default = "default";
      description = ''
        Intel HWP Energy Performance Preference (EPP). Controls the bias between
        performance and power savings within the current governor constraints.
        "balance_power" reduces idle frequency further without impacting throughput.
      '';
    };
  };

  config = {
    # thermald is useful on generic Intel laptops, but on ThinkPad platforms
    # it often exits early due to platform checks and provides no control.
    services.thermald.enable = lib.mkIf (cfg.platform == "generic") true;

    # Re-applied after every resume: the kernel resets the EPP sysfs knob across a
    # suspend cycle. Two traps here — `powerManagement.powerUpCommands` is
    # deprecated and goes away in 26.11, and `post-resume.target` was REMOVED in
    # 26.05, so a unit hung off it silently never runs. Ordering After= the
    # sleep targets is the documented replacement: each is reached only once
    # systemd-suspend.service returns, i.e. after the machine has woken.
    systemd.services.cpu-power-tuning = lib.mkIf (cfg.energyPerformancePreference != "default") {
      description = "Apply CPU turbo/EPP power tuning";

      wantedBy = [
        "multi-user.target"
        "suspend.target"
        "hibernate.target"
        "hybrid-sleep.target"
        "suspend-then-hibernate.target"
      ];
      after = [
        "suspend.target"
        "hibernate.target"
        "hybrid-sleep.target"
        "suspend-then-hibernate.target"
      ];

      # Deliberately no RemainAfterExit: an already-active oneshot would not
      # re-run when the sleep targets pull it in again on resume.
      serviceConfig.Type = "oneshot";

      enableStrictShellChecks = true;
      script = ''

        applied=0
        for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
          [ -w "$f" ] || continue
          echo ${cfg.energyPerformancePreference} > "$f"
          applied=$((applied + 1))
        done
        echo "cpu-power-tuning: EPP ${cfg.energyPerformancePreference} applied to $applied CPU(s)"

      '';
    };

    boot.extraModprobeConfig = lib.mkIf (cfg.platform == "thinkpad") ''
      options thinkpad_acpi fan_control=1
    '';

    services.thinkfan = lib.mkIf (cfg.platform == "thinkpad") {
      enable = true;

      sensors = [
        {
          type = "hwmon";
          query = "/sys/devices/platform/coretemp.0/hwmon";
          indices = [ 1 ]; # Package temp (most relevant)
        }
      ];

      # ThinkPad fan (controls both fans via single interface)
      fans = [
        {
          type = "tpacpi";
          query = "/proc/acpi/ibm/fan";
        }
      ];

      # Fan levels: (level, low_temp, high_temp)
      # level 0 = fan off, 7 = max, "level auto" = BIOS control
      levels = [
        # Fan stays off below 60C, then ramps gradually.
        [
          0
          0
          60
        ]
        [
          1
          57
          65
        ]
        [
          2
          62
          70
        ]
        [
          3
          67
          75
        ]
        [
          4
          72
          80
        ]
        [
          5
          77
          85
        ]
        [
          6
          82
          90
        ]
        [
          7
          87
          95
        ]
        [
          "level full-speed"
          93
          32767
        ]
      ];
    };

    boot.kernelModules = lib.mkIf (cfg.platform == "thinkpad") [ "thinkpad_acpi" ];
  };
}
