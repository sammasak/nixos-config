# Hardware-in-the-loop test of the rf-ap-kick primitive on naked-pi's two real
# radios: onboard wlan0 as a throwaway WPA2 AP, the USB adapter (rtl8192cu) as an
# enrolled station, one hostapd_cli deauth, timed reassociation — real RF, not
# hwsim. The gate is fail-closed and session-aware: it refuses unless EVERY
# default route rides a non-wireless link AND no established SSH session sits on a
# radio interface, so it structurally cannot cut the link the way enabling the AP
# on wlan0 would. Closes #38's hardware gap only when actually run with Ethernet.
{ config, lib, pkgs, ... }:
let
  cfg = config.sam.rfLab;
  username = config.sam.profile.username;

  rfApKickHil = pkgs.writeShellApplication {
    name = "rf-ap-kick-hil";
    runtimeInputs = with pkgs; [
      hostapd wpa_supplicant iw iproute2 networkmanager systemd util-linux
      gnugrep gnused gawk coreutils
    ];
    text = ''
      apif=wlan0
      sta=$(iw dev | awk '/Interface/{print $2}' | grep -m1 '^wlu' || true)

      refuse() {
        printf '{"mode":"refused","reason":"%s","ap_if":"%s","sta_if":"%s"}\n' \
          "$1" "$apif" "''${sta:-none}" >&2
        exit 2
      }

      [ -n "''${sta:-}" ] || { echo "no USB wlan adapter (wlu*) present; plug it in" >&2; exit 1; }

      # One rf-lab radio op at a time: rf-capture/rf-sweep flip wlu* to monitor and
      # their restore would fight ours. flock serialises them.
      exec 9>/run/rf-lab.lock
      flock -n 9 || refuse "another rf-lab operation holds the lock"

      # A running lab AP already owns wlan0; don't stamp on it.
      if systemctl is-active --quiet rf-lab-ap; then
        refuse "rf-lab-ap service is running on wlan0; stop it before the HIL test"
      fi

      # FAIL-CLOSED GATE. Management must ride only non-wireless links, and no SSH
      # session may sit on a radio. Any parse glitch falls through to a refusal.
      mgmt_devs=$( { ip -4 route show default; ip -6 route show default; } 2>/dev/null \
        | grep -oE 'dev [^ ]+' | awk '{print $2}' | sort -u || true)
      [ -n "$mgmt_devs" ] || refuse "no default route; cannot confirm an independent management path"
      for d in $mgmt_devs; do
        if [ "$d" = "$apif" ] || [ "$d" = "$sta" ] || [ -d "/sys/class/net/$d/wireless" ]; then
          refuse "a default route rides a wireless/radio interface ($d); plug in Ethernet"
        fi
        [ -e "/sys/class/net/$d" ] || refuse "default-route device $d is not a real link"
      done

      # Prove the SSH session itself is not on a radio: compare established :22
      # local addresses against the AP/station radio addresses. ss, not
      # $SSH_CONNECTION, because sudo clears the env and a var could be spoofed.
      radio_addrs=$( { ip -o addr show dev "$apif"; ip -o addr show dev "$sta"; } 2>/dev/null \
        | awk '{print $4}' | cut -d/ -f1 || true)
      ssh_laddrs=$(ss -Htn state established '( sport = :22 )' 2>/dev/null \
        | awk '{print $3}' | sed -E 's/:[0-9]+$//; s/[][]//g' || true)
      for la in $ssh_laddrs; do
        for ra in $radio_addrs; do
          [ -n "$la" ] && [ "$la" = "$ra" ] && refuse "an SSH session is on a radio interface ($la); plug in Ethernet"
        done
      done

      if [ "''${1:-}" != "--commit" ]; then
        printf '{"mode":"dry-run","mgmt_devs":"%s","ap_if":"%s","sta_if":"%s","note":"gate passed (mgmt is non-wireless, SSH not on a radio); pass --commit to run the real test"}\n' \
          "$(echo "$mgmt_devs" | tr '\n' ',' | sed 's/,$//')" "$apif" "$sta"
        exit 0
      fi

      tmp=$(mktemp -d)
      restore() {
        [ -f "$tmp/hostapd.pid" ] && kill "$(cat "$tmp/hostapd.pid")" 2>/dev/null || true
        [ -f "$tmp/wpa.pid" ] && kill "$(cat "$tmp/wpa.pid")" 2>/dev/null || true
        sleep 1
        ip addr flush dev "$apif" >/dev/null 2>&1 || true
        ip link set "$sta" down >/dev/null 2>&1 || true
        nmcli dev set "$apif" managed yes >/dev/null 2>&1 || true
        nmcli dev connect "$apif" >/dev/null 2>&1 || true
        rm -rf "$tmp"
      }
      trap restore EXIT

      umask 077
      psk=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
      ssid=naked-hil
      stamac=$(cat /sys/class/net/"$sta"/address)

      nmcli dev set "$apif" managed no >/dev/null 2>&1 || true
      ip addr flush dev "$apif" 2>/dev/null || true
      cat >"$tmp/hostapd.conf" <<EOF
      interface=$apif
      driver=nl80211
      ssid=$ssid
      hw_mode=g
      channel=6
      wpa=2
      wpa_key_mgmt=WPA-PSK
      rsn_pairwise=CCMP
      ctrl_interface=$tmp/hapd
      EOF
      echo "wpa_passphrase=$psk" >>"$tmp/hostapd.conf"
      hostapd -B -P "$tmp/hostapd.pid" "$tmp/hostapd.conf" >/dev/null 2>&1 \
        || { echo "hostapd failed to start on $apif" >&2; exit 1; }
      ip addr add 10.77.0.1/24 dev "$apif" 2>/dev/null || true

      cat >"$tmp/wpa.conf" <<EOF
      ctrl_interface=$tmp/wpa
      network={
        ssid="$ssid"
        psk="$psk"
      }
      EOF
      ip link set "$sta" up 2>/dev/null || true
      wpa_supplicant -B -P "$tmp/wpa.pid" -i "$sta" -c "$tmp/wpa.conf" >/dev/null 2>&1 || true

      assoc=no
      for _ in $(seq 1 20); do
        if iw dev "$sta" link 2>/dev/null | grep -qi "Connected to"; then assoc=yes; break; fi
        sleep 1
      done
      if [ "$assoc" != yes ]; then
        printf '{"kind":"hardware","ssid":"%s","station":"%s","association":"no","note":"station did not associate (rtl8192cu is fragile; replug or retry)"}\n' \
          "$ssid" "$stamac"
        exit 1
      fi

      # The rf-ap-kick primitive against a REAL associated station over real RF.
      kstart=$(date +%s)
      deauth=$(hostapd_cli -p "$tmp/hapd" -i "$apif" deauthenticate "$stamac" 2>&1 || true)
      kicked=no
      for _ in $(seq 1 10); do
        if ! iw dev "$sta" link 2>/dev/null | grep -qi "Connected to"; then kicked=yes; break; fi
        sleep 1
      done
      kickback=na
      if [ "$kicked" = yes ]; then
        kickback=timeout
        for _ in $(seq 1 20); do
          if iw dev "$sta" link 2>/dev/null | grep -qi "Connected to"; then kickback=$(( $(date +%s) - kstart )); break; fi
          sleep 1
        done
      fi
      printf '{"kind":"hardware","ssid":"%s","station":"%s","association":"yes","deauth_result":"%s","kicked":"%s","kick_reassoc_s":"%s","ap_if":"%s","sta_if":"%s","kernel":"%s"}\n' \
        "$ssid" "$stamac" "$deauth" "$kicked" "$kickback" "$apif" "$sta" "$(uname -r)"

      # Green only when the primitive actually worked: station dropped and recovered.
      case "$kickback" in "" | *[!0-9]*) exit 1 ;; esac
      [ "$kicked" = yes ] || exit 1
    '';
  };
in
{
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ rfApKickHil ];

    # NOPASSWD only for this wrapper; its fail-closed gate refuses to run unless
    # management is on a separate wired link, so it cannot be used to strand the Pi.
    security.sudo.extraRules = [
      {
        users = [ username ];
        commands = [
          {
            command = "/run/current-system/sw/bin/rf-ap-kick-hil";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];
  };
}
