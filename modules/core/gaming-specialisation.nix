# Gaming specialisation (Steam + GameMode + Gamescope) for gaming desktops.
#
# Enabled when `sam.profile.games = true`.
{ config, lib, pkgs, ... }:
let
  profile = config.sam.profile;
  hasHomelabK3s = (config ? homelab) && (config.homelab ? k3s);

  # Optional host-local fancontrol config.
  #
  # Generate with `sudo pwmconfig` and paste the resulting /etc/fancontrol into:
  #   hosts/<hostname>/fancontrol-worker.conf
  # Optionally provide a separate curve for gaming:
  #   hosts/<hostname>/fancontrol-gaming.conf
  fancontrolWorkerFile = ../../hosts + "/${profile.hostname}/fancontrol-worker.conf";
  fancontrolGamingFile = ../../hosts + "/${profile.hostname}/fancontrol-gaming.conf";
  fancontrolLegacyFile = ../../hosts + "/${profile.hostname}/fancontrol.conf";

  resolvedFancontrolWorkerFile =
    if builtins.pathExists fancontrolWorkerFile then
      fancontrolWorkerFile
    else if builtins.pathExists fancontrolLegacyFile then
      fancontrolLegacyFile
    else
      null;

  resolvedFancontrolGamingFile =
    if builtins.pathExists fancontrolGamingFile then
      fancontrolGamingFile
    else
      resolvedFancontrolWorkerFile;

  hasFancontrolWorker = resolvedFancontrolWorkerFile != null;
  hasFancontrolGaming = resolvedFancontrolGamingFile != null;

  openrgbOff = pkgs.writeShellApplication {
    name = "openrgb-off";
    runtimeInputs = [ pkgs.openrgb ];
    text = ''
      # OpenRGB is a Qt app; force a headless backend.
      export QT_QPA_PLATFORM=offscreen

      # Best-effort: if there are no supported RGB devices, OpenRGB may exit
      # non-zero. We don't want a failed LED action to break boot.
      set +e
      openrgb --noautoconnect --color 000000
      exit 0
    '';
  };
in
{
  config = lib.mkIf (profile.games or false) {
    # Hardware control baseline for gaming desktops.
    #
    # - Enable i2c for RGB controllers and hwmon devices
    # - Load common Intel/AMD SMBus modules + a common Super I/O hwmon module
    # - Install OpenRGB + its udev rules (but do not run the server)
    hardware.i2c.enable = true;
    users.users.${profile.username}.extraGroups = lib.mkAfter [ config.hardware.i2c.group ];

    boot.kernelModules = lib.mkAfter (
      [
        "nct6775"
      ]
      ++ lib.optionals config.hardware.cpu.intel.updateMicrocode [ "i2c-i801" ]
      ++ lib.optionals config.hardware.cpu.amd.updateMicrocode [ "i2c-piix4" ]
    );

    services.udev.packages = lib.mkAfter [ pkgs.openrgb ];
    environment.systemPackages = lib.mkAfter [ pkgs.openrgb ];

    # Worker mode: turn off RGB at boot (best-effort).
    systemd.services.openrgb-off = {
      description = "Turn off RGB lighting (worker mode)";
      wantedBy = [ "multi-user.target" ];
      wants = [ "systemd-udev-settle.service" ];
      after = [ "systemd-udev-settle.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${openrgbOff}/bin/openrgb-off";
      };
    };

    # Optional motherboard/case fan control (if a config exists).
    hardware.fancontrol = lib.mkIf hasFancontrolWorker {
      enable = true;
      config = builtins.readFile resolvedFancontrolWorkerFile;
    };

    # Generic CPU thermal management can help reduce sustained boost and noise.
    services.thermald.enable = true;

    # Expose power profiles (lets you quickly switch to balanced/performance).
    services.power-profiles-daemon.enable = true;

    specialisation.gaming.configuration = lib.mkMerge [
      {
        # Ensure we drop out of worker-node mode when booting into "gaming".
        services.k3s.enable = lib.mkForce false;

        # Gaming stack
        programs.steam.enable = true;
        hardware.steam-hardware.enable = true;

        programs.gamemode.enable = true;

        # Gamescope is used via Steam launch options like:
        #   gamescope -- %command%
        programs.gamescope.enable = true;
        # Leave capSysNice disabled (default). Enabling it has caused Steam
        # launch-option breakage in some nixpkgs versions.
        # programs.gamescope.capSysNice = true;

        # In gaming mode, don't force RGB off at boot.
        systemd.services.openrgb-off.wantedBy = lib.mkForce [ ];

        # Optional alternate fan curve for gaming mode.
        hardware.fancontrol = lib.mkIf hasFancontrolGaming {
          enable = true;
          config = builtins.readFile resolvedFancontrolGamingFile;
        };
      }

      # If the homelab k3s wrapper module is in use, disable it too so it
      # doesn't leave extra sysctls/kernel modules/firewall rules behind.
      (lib.mkIf hasHomelabK3s {
        homelab.k3s.enable = lib.mkForce false;
      })
    ];
  };
}
