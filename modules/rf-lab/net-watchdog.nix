# Self-healing for the management network. naked-pi is reachable only over
# Ethernet or the onboard Wi-Fi; a wedged NetworkManager state (as happened
# during DHCP work) can strand the headless box with no console. This timer
# recovers it: only when the gateway is unreachable for several consecutive
# checks does it restart NetworkManager and re-up home-wifi — it never touches a
# link that is working, so it cannot disrupt an active management path.
{ config, lib, pkgs, ... }:
let
  cfg = config.sam.rfLab.netWatchdog;
  check = pkgs.writeShellApplication {
    name = "rf-net-watchdog";
    runtimeInputs = with pkgs; [ iputils networkmanager systemd util-linux coreutils ];
    text = ''
      gw=${cfg.gateway}
      state=/run/rf-net-watchdog.fails
      if ping -c1 -W2 "$gw" >/dev/null 2>&1; then
        echo 0 > "$state"
        exit 0
      fi
      fails=$(( $(cat "$state" 2>/dev/null || echo 0) + 1 ))
      echo "$fails" > "$state"
      logger -t rf-net-watchdog "gateway $gw unreachable ($fails/${toString cfg.threshold})"
      if [ "$fails" -ge ${toString cfg.threshold} ]; then
        logger -t rf-net-watchdog "recovering: restart NetworkManager + re-up home-wifi"
        systemctl restart NetworkManager || true
        sleep 10
        nmcli connection up home-wifi || true
        echo 0 > "$state"
      fi
    '';
  };
in
{
  options.sam.rfLab.netWatchdog = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.sam.rfLab.enable;
      description = "Self-heal a wedged management network by re-upping NetworkManager/Wi-Fi.";
    };
    gateway = lib.mkOption {
      type = lib.types.str;
      default = "192.168.10.1";
      description = "Reachability probe target; unreachable = no management path.";
    };
    threshold = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = "Consecutive failed checks before recovery (× the 2-min timer).";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.rf-net-watchdog = {
      description = "rf-lab management-network watchdog";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe check;
      };
    };
    systemd.timers.rf-net-watchdog = {
      description = "rf-lab management-network watchdog timer";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3min";
        OnUnitActiveSec = "2min";
        Persistent = true;
      };
    };
  };
}
