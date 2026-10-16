# Hardware-in-the-loop test of the rf-ap-kick primitive on naked-pi's two real
# radios: onboard wlan0 as a throwaway WPA2 AP, the USB adapter (rtl8192cu) as an
# enrolled station, one hostapd_cli deauth, timed reassociation — real RF, not
# hwsim. Refuses unless the management path is a THIRD interface (Ethernet), so it
# structurally cannot cut the SSH link the way enabling the AP on wlan0 would.
# Closes #38's hardware gap only when actually run with Ethernet present.
{ config, lib, pkgs, ... }:
let
  cfg = config.sam.rfLab;
  username = config.sam.profile.username;

  rfApKickHil = pkgs.writeShellApplication {
    name = "rf-ap-kick-hil";
    runtimeInputs = with pkgs; [
      hostapd wpa_supplicant iw iproute2 networkmanager gnugrep gawk coreutils
    ];
    text = ''
      apif=wlan0
      sta=$(iw dev | awk '/Interface/{print $2}' | grep -m1 '^wlu' || true)
      if [ -z "''${sta:-}" ]; then
        echo "no USB wlan adapter (wlu*) present; plug it in and retry" >&2
        exit 1
      fi

      # HARD GATE: management must ride a third interface (Ethernet). If the
      # default route is via the AP radio or the station radio, running would
      # cut our own SSH, so refuse. This is why the test is safe to leave armed.
      mgmt=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
      if [ -z "''${mgmt:-}" ] || [ "$mgmt" = "$apif" ] || [ "$mgmt" = "$sta" ]; then
        printf '{"mode":"refused","reason":"management path must be a separate (Ethernet) interface, not the AP or station radio","mgmt":"%s","ap_if":"%s","sta_if":"%s"}\n' \
          "''${mgmt:-none}" "$apif" "$sta" >&2
        echo "Plug in Ethernet and confirm 'ip route' default is via eth0/enu* before running." >&2
        exit 2
      fi

      if [ "''${1:-}" != "--commit" ]; then
        printf '{"mode":"dry-run","mgmt":"%s","ap_if":"%s","sta_if":"%s","note":"management path OK (not AP/STA radio); pass --commit to run the real two-radio test"}\n' \
          "$mgmt" "$apif" "$sta"
        exit 0
      fi

      tmp=$(mktemp -d)
      umask 077
      psk=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
      ssid=naked-hil
      stamac=$(cat /sys/class/net/"$sta"/address)

      restore() {
        hostapd_cli -p "$tmp/hapd" -i "$apif" terminate >/dev/null 2>&1 || true
        pkill -f "wpa_supplicant.*$sta" >/dev/null 2>&1 || true
        ip addr flush dev "$apif" >/dev/null 2>&1 || true
        ip link set "$sta" down >/dev/null 2>&1 || true
        nmcli dev set "$apif" managed yes >/dev/null 2>&1 || true
        nmcli dev connect "$apif" >/dev/null 2>&1 || true
        rm -rf "$tmp"
      }
      trap restore EXIT

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
      wpa_passphrase=$psk
      EOF
      hostapd -B "$tmp/hostapd.conf" >/dev/null 2>&1 || { echo "hostapd failed to start on $apif" >&2; exit 1; }
      ip addr add 10.77.0.1/24 dev "$apif" 2>/dev/null || true

      cat >"$tmp/wpa.conf" <<EOF
      ctrl_interface=$tmp/wpa
      network={
        ssid="$ssid"
        psk="$psk"
      }
      EOF
      ip link set "$sta" up 2>/dev/null || true
      wpa_supplicant -B -i "$sta" -c "$tmp/wpa.conf" >/dev/null 2>&1 || true

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
      hostapd_cli -p "$tmp/hapd" -i "$apif" deauthenticate "$stamac" >/dev/null 2>&1 || true
      kicked=no
      for _ in $(seq 1 10); do
        if ! iw dev "$sta" link 2>/dev/null | grep -qi "Connected to"; then kicked=yes; break; fi
        sleep 1
      done
      kickback=timeout
      for _ in $(seq 1 20); do
        if iw dev "$sta" link 2>/dev/null | grep -qi "Connected to"; then kickback=$(( $(date +%s) - kstart )); break; fi
        sleep 1
      done
      printf '{"kind":"hardware","ssid":"%s","station":"%s","association":"yes","kicked":"%s","kick_reassoc_s":"%s","ap_if":"%s","sta_if":"%s","kernel":"%s"}\n' \
        "$ssid" "$stamac" "$kicked" "$kickback" "$apif" "$sta" "$(uname -r)"
    '';
  };
in
{
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ rfApKickHil ];

    # NOPASSWD only for this wrapper; its own hard gate refuses to run unless
    # management is on a separate interface, so it cannot be used to strand the Pi.
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
