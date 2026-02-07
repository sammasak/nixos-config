# Thermal management for quiet laptop operation
# Configures thinkfan for ThinkPads/Lenovo with conservative fan curves
{ config, lib, pkgs, ... }:

let
  cfg = config.hardware.thermal;
in
{
  options.hardware.thermal = {
    enable = lib.mkEnableOption "thermal management with quiet fan control";

    platform = lib.mkOption {
      type = lib.types.enum [ "thinkpad" "generic" ];
      default = "generic";
      description = "Hardware platform for fan control";
    };

    profile = lib.mkOption {
      type = lib.types.enum [ "quiet" "balanced" "performance" ];
      default = "quiet";
      description = "Fan curve profile";
    };
  };

  config = lib.mkIf cfg.enable {
    # thermald is useful on generic Intel laptops, but on ThinkPad platforms
    # it often exits early due to platform checks and provides no control.
    services.thermald.enable = lib.mkIf (cfg.platform == "generic") true;

    # ThinkPad-specific fan control
    boot.extraModprobeConfig = lib.mkIf (cfg.platform == "thinkpad") ''
      options thinkpad_acpi fan_control=1
    '';

    # Thinkfan service for custom fan curves
    services.thinkfan = lib.mkIf (cfg.platform == "thinkpad") {
      enable = true;

      # Use coretemp for accurate CPU package temperature
      sensors = [
        {
          type = "hwmon";
          query = "/sys/devices/platform/coretemp.0/hwmon";
          indices = [ 1 ];  # Package temp (most relevant)
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
      levels =
        if cfg.profile == "quiet" then [
          # Quiet profile: fan stays off below 60C, then ramps gradually.
          [ 0     0   60 ]   # Fan off up to 60°C
          [ 1    57   65 ]   # Level 1: 57-65°C
          [ 2    62   70 ]   # Level 2: 62-70°C
          [ 3    67   75 ]   # Level 3: 67-75°C
          [ 4    72   80 ]   # Level 4: 72-80°C
          [ 5    77   85 ]   # Level 5: 77-85°C
          [ 6    82   90 ]   # Level 6: 82-90°C
          [ 7    87   95 ]   # Level 7: 87-95°C (max)
          [ "level full-speed" 93 32767 ]  # Emergency
        ]
        else if cfg.profile == "balanced" then [
          # Balanced profile: reasonable compromise
          [ 0     0   50 ]
          [ 1    47   55 ]
          [ 2    52   60 ]
          [ 3    57   65 ]
          [ 4    62   70 ]
          [ 5    67   75 ]
          [ 6    72   80 ]
          [ 7    77   90 ]
          [ "level full-speed" 88 32767 ]
        ]
        else [
          # Performance profile: keeps temps lower
          [ 0     0   45 ]
          [ 2    42   50 ]
          [ 4    47   55 ]
          [ 5    52   60 ]
          [ 6    57   70 ]
          [ 7    65   85 ]
          [ "level full-speed" 82 32767 ]
        ];
    };

    # Ensure thinkpad_acpi module is loaded
    boot.kernelModules = lib.mkIf (cfg.platform == "thinkpad") [ "thinkpad_acpi" ];
  };
}
