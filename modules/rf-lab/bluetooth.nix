# Owned Bluetooth chaos experiments (#39): disconnect/reconnect and local-adapter
# outage for a device PAIRED TO THIS Pi, via BlueZ. Opt-in, off by default. These
# act only through our own controller on an enrolled paired device — never a
# capability to disconnect arbitrary nearby Bluetooth devices. Physical use is
# gated on a working controller; naked-pi's onboard hci0 is undervoltage-flaky,
# so the wrappers fail closed when it is down.
{ config, lib, pkgs, ... }:
let
  cfg = config.sam.rfLab.bluetooth;
  enrolled = lib.concatStringsSep " " (map lib.toLower cfg.pairedDevices);

  rfBtDisconnect = pkgs.writeShellApplication {
    name = "rf-bt-disconnect";
    runtimeInputs = with pkgs; [ bluez gnugrep coreutils ];
    text = ''
      mac=$(printf '%s' "''${1:?usage: rf-bt-disconnect <enrolled-MAC> [--commit]}" | tr '[:upper:]' '[:lower:]')
      commit=''${2:-}
      enrolled="${enrolled}"
      case " $enrolled " in *" $mac "*) ;; *) echo "refused: $mac not in pairedDevices" >&2; exit 1 ;; esac
      if ! timeout 8 bluetoothctl show >/dev/null 2>&1; then
        echo "bluetooth controller unavailable (hci0 down; see undervoltage note)" >&2; exit 1
      fi
      if ! bluetoothctl info "$mac" 2>/dev/null | grep -qi "Connected: yes"; then
        echo "refused: $mac is not currently connected to this controller" >&2; exit 1
      fi
      if [ "$commit" != "--commit" ]; then
        printf '{"device":"%s","action":"disconnect","mode":"dry-run","connected":true}\n' "$mac"
        exit 0
      fi
      out=$(bluetoothctl disconnect "$mac" 2>&1 | tr '\n' ' ' || true)
      printf '{"device":"%s","action":"disconnect","mode":"commit","result":"%s"}\n' "$mac" "$out"
    '';
  };

  rfBtAdapterOutage = pkgs.writeShellApplication {
    name = "rf-bt-adapter-outage";
    runtimeInputs = with pkgs; [ bluez coreutils ];
    text = ''
      secs=''${1:-10}
      if ! timeout 8 bluetoothctl show >/dev/null 2>&1; then
        echo "bluetooth controller unavailable (hci0 down)" >&2; exit 1
      fi
      start=$(date +%s)
      bluetoothctl power off >/dev/null 2>&1 || true
      sleep "$secs"
      bluetoothctl power on >/dev/null 2>&1 || true
      for _ in $(seq 1 10); do bluetoothctl show 2>/dev/null | grep -qi "Powered: yes" && break; sleep 1; done
      printf '{"action":"adapter-outage","seconds":%s,"restored_after":%s}\n' "$secs" "$(( $(date +%s) - start ))"
    '';
  };

  rfBtStatus = pkgs.writeShellApplication {
    name = "rf-bt-status";
    runtimeInputs = with pkgs; [ bluez coreutils ];
    text = ''
      if ! timeout 8 bluetoothctl show >/dev/null 2>&1; then
        echo "bluetooth controller unavailable (hci0 down)" >&2; exit 1
      fi
      bluetoothctl show | grep -iE "Name|Powered|Discovering"
      echo "== paired devices:"; bluetoothctl devices Paired 2>/dev/null || bluetoothctl paired-devices
    '';
  };
  btTools = [ rfBtDisconnect rfBtAdapterOutage rfBtStatus ];
in
{
  options.sam.rfLab.bluetooth = {
    enable = lib.mkEnableOption "owned Bluetooth chaos experiments (BlueZ, paired devices)";
    pairedDevices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "MACs of devices paired to this Pi that rf-bt-disconnect may act on.";
    };
  };

  config = lib.mkIf (config.sam.rfLab.enable && cfg.enable) {
    hardware.bluetooth.enable = true;
    environment.systemPackages = (with pkgs; [ bluez ]) ++ btTools;

    security.sudo.extraRules = [
      {
        users = [ config.sam.profile.username ];
        commands = map (t: {
          command = "/run/current-system/sw/bin/${t.meta.mainProgram or t.name}";
          options = [ "NOPASSWD" ];
        }) btTools;
      }
    ];
  };
}
