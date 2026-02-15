# Host configuration for msi-ms7758
{ lib, pkgs, ... }:
let
  vars = import ./variables.nix;

  # Auto power schedule (disabled by default). When enabled, a timer triggers
  # at `powerOffTime` and powers the machine off using `rtcwake`, scheduling the
  # next wakeup at the next occurrence of `wakeUpTime`.
  #
  # This works only if the motherboard supports RTC wake from S5 (soft-off) and
  # the relevant firmware settings are enabled.
  autoPower = {
    enable = false;
    powerOffTime = "02:00";
    wakeUpTime = "07:00";
  };

  rtcwakePoweroff = pkgs.writeShellApplication {
    name = "rtcwake-poweroff";
    runtimeInputs = [ pkgs.coreutils pkgs.util-linux ];
    text = ''
      set -euo pipefail

      wake_time="$1"
      # Next occurrence of wake_time (today if still upcoming, otherwise tomorrow).
      now_epoch="$(date +%s)"
      today_epoch="$(date -d "today $wake_time" +%s || true)"
      if [[ -z "$today_epoch" ]] || [[ "$today_epoch" -le "$now_epoch" ]]; then
        wake_epoch="$(date -d "tomorrow $wake_time" +%s)"
      else
        wake_epoch="$today_epoch"
      fi

      echo "Scheduling RTC wake for $(date -d "@$wake_epoch" --iso-8601=seconds) and powering off..."
      exec rtcwake -m off -t "$wake_epoch"
    '';
  };
in
{
  imports = [
    ./hardware-configuration.nix

    # Hardware
    ../../modules/hardware/video/${vars.videoDriver}.nix

    # Keep GRUB theming consistent with the other machines (Stylix).
    ../../modules/themes/Catppuccin
  ];

  sam.profile = vars;

  # Headless GPU worker: prepare NVIDIA for container workloads.
  hardware.nvidia-container-toolkit.enable = true;

  # Ollama backend (kept local by default; expose via SSH tunnel or add firewall
  # rules if you want LAN access).
  services.ollama = {
    enable = true;
    # Kepler + legacy 470xx: CUDA builds are often incompatible; try Vulkan first.
    package = pkgs.ollama-vulkan;
    host = "127.0.0.1";
    openFirewall = false;
  };

  # Wake-on-LAN (WoL)
  #
  # NIC: enp3s0 (MAC: d4:3d:7e:4a:f9:3d)
  networking.interfaces.enp3s0.wakeOnLan.enable = true;
  environment.systemPackages = lib.mkAfter [
    pkgs.ethtool
  ];

  # NetworkManager can sometimes reset WoL flags; enforce it after boot.
  systemd.services.wol-enp3s0 = {
    description = "Enable Wake-on-LAN on enp3s0";
    wantedBy = [ "multi-user.target" ];
    after = [ "NetworkManager.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.ethtool}/bin/ethtool -s enp3s0 wol g";
    };
  };

  # Scheduled power off/on (via RTC wake). Disabled by default.
  systemd.services.msi-rtcwake-poweroff = lib.mkIf autoPower.enable {
    description = "Power off and schedule RTC wake (msi-ms7758)";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${rtcwakePoweroff}/bin/rtcwake-poweroff ${autoPower.wakeUpTime}";
    };
  };

  systemd.timers.msi-rtcwake-poweroff = lib.mkIf autoPower.enable {
    description = "Scheduled power off (msi-ms7758)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* ${autoPower.powerOffTime}:00";
      Persistent = true;
    };
  };

  # Shared Windows ESP is only 100 MiB; keep the GRUB menu short.
  boot.loader.grub.configurationLimit = 5;

  # Windows entry for GRUB (works when booted in UEFI mode).
  boot.loader.grub.extraEntries = ''
    menuentry "Windows Boot Manager" {
      insmod part_gpt
      insmod fat
      insmod chain
      search --no-floppy --file --set=root /EFI/Microsoft/Boot/bootmgfw.efi
      chainloader /EFI/Microsoft/Boot/bootmgfw.efi
    }
  '';

  # Desktop tower: no automatic suspend/hibernate behavior.
  services.logind.settings.Login = {
    IdleAction = "ignore";
    HandlePowerKey = "poweroff";
  };

  # k3s agent configuration (worker node by default)
  homelab.k3s.serverAddr = "https://192.168.10.154:6443"; # k3s server on lenovo-21CB001PMX
  homelab.k3s.extraFlags = [
    "--node-label=node-pool=workers"
  ];
}
