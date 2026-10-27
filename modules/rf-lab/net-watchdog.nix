# Self-healing for the management network. naked-pi is reachable only over
# Ethernet or the onboard Wi-Fi; a wedged NetworkManager state (as happened
# during DHCP work) can strand the headless box with no console. This timer
# recovers it, but a gateway ping dropping is not proof of a lost management
# path — ICMP may be filtered while SSH over another link is fine — so it acts
# only when NO interface offers a usable path, prefers the gentlest fix, and
# backs off after a bounded number of tries so a real outage cannot become a
# NetworkManager-restart storm. See vault: homelab/runbooks/naked-pi-rf-lab.md
{ config, lib, pkgs, ... }:
let
  cfg = config.sam.rfLab.netWatchdog;
  check = pkgs.writeShellApplication {
    name = "rf-net-watchdog";
    runtimeInputs = with pkgs; [ iputils networkmanager systemd util-linux coreutils iproute2 gawk bash ];
    text = ''
      gw=${cfg.gateway}
      sshport=${toString cfg.sshPort}
      profile=${cfg.recoveryProfile}
      threshold=${toString cfg.threshold}
      maxattempts=${toString cfg.maxRecoveryAttempts}
      waitfor=${toString cfg.recoveryWait}
      configured=(${lib.concatMapStringsSep " " (i: "\"${i}\"") cfg.managementInterfaces})

      state_fails=/run/rf-net-watchdog.fails
      state_attempts=/run/rf-net-watchdog.attempts

      log() { logger -t rf-net-watchdog "$1"; }

      # Management candidates: the explicit list if given, else every link except
      # loopback and the rf-lab USB capture adapter (wlu*), which is never a path.
      mgmt_ifaces() {
        if [ "''${#configured[@]}" -gt 0 ]; then
          printf '%s\n' "''${configured[@]}"
          return
        fi
        for d in /sys/class/net/*; do
          name=$(basename "$d")
          case "$name" in
            lo|wlu*) continue ;;
          esac
          printf '%s\n' "$name"
        done
      }

      has_carrier() { [ "$(cat "/sys/class/net/$1/carrier" 2>/dev/null || echo 0)" = 1 ]; }
      iface_ipv4() { ip -4 -o addr show dev "$1" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1; }

      # Dial our own sshd on the link's address: proves the management daemon is
      # up and the address locally reachable, independent of ICMP policy.
      ssh_reachable() { timeout 2 bash -c "exec 3<>/dev/tcp/$1/$sshport" 2>/dev/null; }
      gw_via() { ping -c1 -W2 -I "$1" "$gw" >/dev/null 2>&1; }

      # A link carrying traffic we must not disturb: carrier plus a v4 lease.
      link_with_lease() {
        while read -r ifc; do
          [ -n "$ifc" ] || continue
          if has_carrier "$ifc" && [ -n "$(iface_ipv4 "$ifc")" ]; then return 0; fi
        done < <(mgmt_ifaces)
        return 1
      }

      usable_path() {
        while read -r ifc; do
          [ -n "$ifc" ] || continue
          has_carrier "$ifc" || continue
          ip4=$(iface_ipv4 "$ifc")
          [ -n "$ip4" ] || continue
          if ssh_reachable "$ip4" || gw_via "$ifc"; then return 0; fi
        done < <(mgmt_ifaces)
        return 1
      }

      wait_for_path() {
        deadline=$(( $(date +%s) + $1 ))
        while [ "$(date +%s)" -lt "$deadline" ]; do
          if usable_path; then return 0; fi
          sleep 2
        done
        return 1
      }

      if usable_path; then
        rm -f "$state_fails" "$state_attempts"
        exit 0
      fi

      fails=$(( $(cat "$state_fails" 2>/dev/null || echo 0) + 1 ))
      echo "$fails" > "$state_fails"
      log "no usable management path ($fails/$threshold checks)"
      [ "$fails" -ge "$threshold" ] || exit 0

      # Anti-flap: a persistent outage must not restart NetworkManager every tick.
      attempts=$(cat "$state_attempts" 2>/dev/null || echo 0)
      if [ "$attempts" -ge "$maxattempts" ]; then
        log "backing off: $attempts recovery attempts did not restore a path; needs manual intervention"
        exit 0
      fi
      attempts=$(( attempts + 1 ))
      echo "$attempts" > "$state_attempts"

      # Gentlest fix first: re-activate only the Wi-Fi profile, touching no other link.
      log "recovery attempt $attempts/$maxattempts: nmcli up $profile"
      nmcli connection up "$profile" >/dev/null 2>&1 || true
      if wait_for_path "$waitfor"; then
        log "management path restored by re-upping $profile"
        exit 0
      fi

      # Escalate only when nothing holds a lease — restarting NM bounces every
      # managed link, so we refuse to do it while one still has carrier + an address.
      if link_with_lease; then
        log "gentle recovery failed but a link still holds a lease; not restarting NetworkManager"
        exit 0
      fi

      log "gentle recovery failed and no link holds a lease; restarting NetworkManager"
      systemctl restart NetworkManager >/dev/null 2>&1 || true
      nmcli connection up "$profile" >/dev/null 2>&1 || true
      if wait_for_path "$waitfor"; then
        log "management path restored after NetworkManager restart"
      else
        log "recovery attempt $attempts/$maxattempts did not restore a path"
      fi
    '';
  };
in
{
  options.sam.rfLab.netWatchdog = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.sam.rfLab.enable;
      description = "Self-heal a wedged management network, acting only when no link offers a usable path.";
    };
    gateway = lib.mkOption {
      type = lib.types.str;
      default = "192.168.10.1";
      description = "Per-interface ICMP probe target; one reachability signal among several, not the sole trigger.";
    };
    managementInterfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Links to treat as management paths; empty auto-discovers all but loopback and the wlu* capture adapter.";
    };
    sshPort = lib.mkOption {
      type = lib.types.port;
      default = 22;
      description = "Local sshd port dialed on a link's own address to confirm a live management daemon.";
    };
    recoveryProfile = lib.mkOption {
      type = lib.types.str;
      default = "home-wifi";
      description = "NetworkManager profile re-upped as the gentle first recovery step.";
    };
    threshold = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = "Consecutive no-path checks before recovery (× the 2-min timer).";
    };
    maxRecoveryAttempts = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = "Recovery cycles that may run before backing off to log-only, so an outage cannot loop-restart NM.";
    };
    recoveryWait = lib.mkOption {
      type = lib.types.ints.positive;
      default = 20;
      description = "Seconds to wait for a path to return after each recovery step before escalating or giving up.";
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
