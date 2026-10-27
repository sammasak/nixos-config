# Opt-in 2.4 GHz RF lab for naked-pi: passive capture/discovery here, with the
# owned-AP lab (ap.nix) and the Ethernet-gated HIL kick test (hil.nix) as the only
# deauth/AP-mode paths — all scoped to our own AP and enrolled stations, never
# frame injection or anyone else's network. Driven from lenovo by the `rf:*`
# devenv tasks; full context in README.md and the naked-pi-rf-lab.md runbook.
{ config, lib, pkgs, ... }:
let
  cfg = config.sam.rfLab;
  username = config.sam.profile.username;
  radio = import ./radio.nix;
  captureDir = "/var/lib/rf-lab/captures";

  # The USB adapter is the only monitor-capable radio (onboard is 2.4 GHz
  # managed-only).
  pickMon = ''
    exec 9>${radio.lock}
    flock -n 9 || { echo "another rf-lab op holds the radio lock; retry when it finishes" >&2; exit 1; }
    IF=$(${radio.findUsb})
    if [ -z "''${IF:-}" ]; then
      # The rtl8192cu RX path wedges after repeated mode flips or an undervoltage
      # USB brownout; one module reload clears the soft cases, a replug the rest.
      modprobe -r rtl8192cu 2>/dev/null || true; sleep 1
      modprobe rtl8192cu 2>/dev/null || true; sleep 3
      IF=$(${radio.findUsb})
    fi
    if [ -z "''${IF:-}" ]; then
      echo "no USB capture adapter (wlu*) present; replug it (see runbook)" >&2
      exit 1
    fi
  '';

  # Best-effort radio ops: an undervoltage drop mid-run must not abort, and the
  # trap always hands the radio back to managed mode so the kit leaves no mess.
  enterMonitor = ''
    restore() {
      ip link set "$IF" down 2>/dev/null || true
      iw dev "$IF" set type managed 2>/dev/null || true
      ip link set "$IF" up 2>/dev/null || true
    }
    trap restore EXIT
    ip link set "$IF" down 2>/dev/null || true
    iw dev "$IF" set type monitor 2>/dev/null || true
    ip link set "$IF" up 2>/dev/null || true
  '';

  warnEmpty = ''
    if [ "$(tcpdump -r "$out" 2>/dev/null | wc -l)" -eq 0 ]; then
      echo "warning: 0 frames captured — adapter RX likely wedged; replug it and retry" >&2
    fi
  '';

  rfSweep = pkgs.writeShellApplication {
    name = "rf-sweep";
    runtimeInputs = with pkgs; [ iw tcpdump coreutils gawk kmod util-linux ];
    text = ''
      per=''${1:-1.2}
      ${pickMon}
      out="${captureDir}/sweep-$(date +%Y%m%dT%H%M%S).pcap"
      ${enterMonitor}
      tcpdump -i "$IF" -y IEEE802_11_RADIO -s 300 'type mgt subtype beacon' -w "$out" 2>/dev/null &
      tp=$!
      for ch in 1 2 3 4 5 6 7 8 9 10 11 12 13; do
        iw dev "$IF" set channel "$ch" 2>/dev/null || true
        sleep "$per"
      done
      kill "$tp" 2>/dev/null || true
      wait "$tp" 2>/dev/null || true
      chown ${username}:users "$out" 2>/dev/null || true
      ${warnEmpty}
      echo "$out"
    '';
  };

  rfCapture = pkgs.writeShellApplication {
    name = "rf-capture";
    runtimeInputs = with pkgs; [ iw tcpdump coreutils gawk kmod util-linux ];
    text = ''
      ch=''${1:?usage: rf-capture <channel> [seconds] [bpf-filter]}
      secs=''${2:-30}
      filter=''${3:-}
      ${pickMon}
      out="${captureDir}/capture-ch''${ch}-$(date +%Y%m%dT%H%M%S).pcap"
      ${enterMonitor}
      iw dev "$IF" set channel "$ch" 2>/dev/null || true
      # shellcheck disable=SC2086
      timeout "$secs" tcpdump -i "$IF" -y IEEE802_11_RADIO -s 0 -w "$out" $filter 2>/dev/null || true
      chown ${username}:users "$out" 2>/dev/null || true
      ${warnEmpty}
      echo "$out"
    '';
  };

  # Onboard BT is flaky on this board (UART init fails under undervoltage), so
  # bound the whole run: bluetoothctl --timeout alone has been seen to hang.
  rfBtScan = pkgs.writeShellApplication {
    name = "rf-btscan";
    runtimeInputs = with pkgs; [ bluez coreutils ];
    text = ''
      secs=''${1:-15}
      if ! timeout 8 bluetoothctl show >/dev/null 2>&1; then
        echo "bluetooth controller unavailable (hci0 down; see undervoltage note in runbook)" >&2
        exit 1
      fi
      timeout "$((secs + 10))" bluetoothctl --timeout "$secs" scan on >/dev/null 2>&1 || true
      bluetoothctl devices
    '';
  };

  # Fully virtual Wi-Fi lab: two mac80211_hwsim radios in a throwaway netns run a
  # real hostapd + wpa_supplicant association and an iperf3 transfer, then a
  # disconnect/reconnect, with timed recovery. No physical radio, no real RF, no
  # effect on enu1u1/wlan0 or anyone else. Teardown rmmods the module.
  rfSim = pkgs.writeShellApplication {
    name = "rf-sim";
    runtimeInputs = with pkgs; [ kmod iw iproute2 hostapd wpa_supplicant iperf3 coreutils gnugrep ];
    text = ''
      loss=''${1:-0}      # arg1: tc-netem loss percent on the station link (0 = perfect)
      outage=''${2:-1}    # arg2: seconds the station stays disconnected
      kick=''${3:-0}      # arg3: 1 = AP-initiated hostapd deauth (the rf-ap-kick primitive), observed
      apns=rfsim-ap; stns=rfsim-sta
      tmp=$(mktemp -d)
      cleanup() {
        for n in "$apns" "$stns"; do
          ip netns pids "$n" 2>/dev/null | xargs -r kill 2>/dev/null || true
          ip netns del "$n" 2>/dev/null || true
        done
        modprobe -r mac80211_hwsim 2>/dev/null || true
        rm -rf "$tmp"
      }
      trap cleanup EXIT
      modprobe -r mac80211_hwsim 2>/dev/null || true

      # Two netns each holding one hwsim radio: bare hwsim carries data between
      # them (verified on this kernel). wmediumd is NOT used — in a shared netns it
      # dropped all data frames; loss is modelled with tc-netem instead (#40).
      # shellcheck disable=SC2012
      before=$(ls /sys/class/ieee80211 2>/dev/null | sort)
      modprobe mac80211_hwsim radios=2
      sleep 1
      # shellcheck disable=SC2012
      after=$(ls /sys/class/ieee80211 2>/dev/null | sort)
      mapfile -t newphys < <(comm -13 <(echo "$before") <(echo "$after"))
      if [ "''${#newphys[@]}" -lt 2 ]; then echo "hwsim did not yield two radios" >&2; exit 1; fi
      ip netns add "$apns"; ip netns add "$stns"
      iw phy "''${newphys[0]}" set netns name "$apns" 2>/dev/null || true
      iw phy "''${newphys[1]}" set netns name "$stns" 2>/dev/null || true
      ap=$(ip netns exec "$apns" sh -c 'ls /sys/class/net | grep "^wlan"' | head -1)
      sta=$(ip netns exec "$stns" sh -c 'ls /sys/class/net | grep "^wlan"' | head -1)
      echo "virtual radios: AP=$ap ($apns) STA=$sta ($stns)"

      cat >"$tmp/hostapd.conf" <<EOF
      interface=$ap
      driver=nl80211
      ssid=naked-sim
      hw_mode=g
      channel=1
      ctrl_interface=$tmp/hapd
      EOF
      cat >"$tmp/wpa.conf" <<EOF
      ctrl_interface=$tmp/wpa
      network={
        ssid="naked-sim"
        key_mgmt=NONE
      }
      EOF

      ip netns exec "$apns" hostapd -B "$tmp/hostapd.conf" >/dev/null 2>&1 || { echo "hostapd failed to start" >&2; exit 1; }
      ip netns exec "$apns" ip addr add 10.77.0.1/24 dev "$ap" 2>/dev/null || true
      ip netns exec "$apns" ip link set "$ap" up 2>/dev/null || true
      ip netns exec "$stns" wpa_supplicant -B -i "$sta" -c "$tmp/wpa.conf" >/dev/null 2>&1 || true

      assoc=no
      for _ in $(seq 1 15); do
        if ip netns exec "$stns" iw dev "$sta" link 2>/dev/null | grep -qi "Connected to"; then assoc=yes; break; fi
        sleep 1
      done
      echo "association: $assoc"
      [ "$assoc" = yes ] || { echo "station did not associate" >&2; exit 1; }
      ip netns exec "$stns" ip addr add 10.77.0.2/24 dev "$sta" 2>/dev/null || true
      ip netns exec "$stns" ip link set "$sta" up 2>/dev/null || true

      if [ "$loss" != "0" ]; then
        ip netns exec "$stns" tc qdisc add dev "$sta" root netem loss "''${loss}%" 2>/dev/null || true
      fi
      sleep 1

      echo "== iperf3 (two-netns virtual link, 3s, loss=''${loss}%):"
      ip netns exec "$apns" iperf3 -s -1 -D >/dev/null 2>&1 || true
      sleep 1
      iperf=$(ip netns exec "$stns" iperf3 --connect-timeout 3000 -c 10.77.0.1 -t 3 2>/dev/null \
        | grep receiver | grep -oE '[0-9.]+ [MKG]bits/sec' | head -1)
      if [ -n "$iperf" ]; then echo "  throughput: $iperf"; else echo "  no data path (unexpected for two-netns)"; fi

      echo "== disconnect/reconnect (outage ''${outage}s):"
      start=$(date +%s)
      ip netns exec "$stns" wpa_cli -i "$sta" -p "$tmp/wpa" disconnect >/dev/null 2>&1 || true
      sleep "$outage"
      ip netns exec "$stns" wpa_cli -i "$sta" -p "$tmp/wpa" reconnect >/dev/null 2>&1 || true
      recovered=timeout
      for _ in $(seq 1 15); do
        if ip netns exec "$stns" iw dev "$sta" link 2>/dev/null | grep -qi "Connected to"; then recovered=$(( $(date +%s) - start )); break; fi
        sleep 1
      done
      echo "  reassociated in ~''${recovered}s"

      kicked=na; kickback=na
      if [ "$kick" = 1 ]; then
        # AP-initiated hostapd deauth is exactly the rf-ap-kick primitive; this
        # observes the drop + auto-reassociation in sim (cipher-independent).
        echo "== AP-initiated deauth (rf-ap-kick primitive):"
        stamac=$(ip netns exec "$stns" cat /sys/class/net/"$sta"/address)
        kstart=$(date +%s)
        ip netns exec "$apns" hostapd_cli -p "$tmp/hapd" -i "$ap" deauthenticate "$stamac" >/dev/null 2>&1 || true
        kicked=no
        for _ in $(seq 1 10); do
          if ! ip netns exec "$stns" iw dev "$sta" link 2>/dev/null | grep -qi "Connected to"; then kicked=yes; break; fi
          sleep 1
        done
        echo "  station dropped by AP deauth: $kicked"
        kickback=timeout
        for _ in $(seq 1 15); do
          if ip netns exec "$stns" iw dev "$sta" link 2>/dev/null | grep -qi "Connected to"; then kickback=$(( $(date +%s) - kstart )); break; fi
          sleep 1
        done
        echo "  reassociated after deauth in ~''${kickback}s"
      fi

      # Deterministic artifact (simulation only — not a hardware measurement).
      printf '{"kind":"simulation","scenario":{"loss_pct":%s,"outage_s":%s,"kick":%s},"association":"%s","throughput":"%s","reassociated_s":"%s","kicked":"%s","kick_reassoc_s":"%s","kernel":"%s"}\n' \
        "$loss" "$outage" "$kick" "$assoc" "''${iperf:-none}" "$recovered" "$kicked" "$kickback" "$(uname -r)"
    '';
  };

  # Chaos/resilience: a bounded outage of the lab's *own* AP (stop then restart
  # hostapd/dnsmasq), timing the restore. Acts only on the rf-lab AP units — no
  # deauth, no frames at other networks. Inert unless sam.rfLab.ap is running.
  rfApOutage = pkgs.writeShellApplication {
    name = "rf-ap-outage";
    runtimeInputs = [ pkgs.systemd pkgs.coreutils ];
    text = ''
      secs=''${1:-10}
      if ! systemctl is-active --quiet rf-lab-ap; then
        echo "lab AP not running (sam.rfLab.ap.enable=false?); nothing to outage" >&2
        exit 1
      fi
      echo "stopping lab AP for ''${secs}s..."
      start=$(date +%s)
      systemctl stop rf-lab-dhcp rf-lab-ap || true
      sleep "$secs"
      systemctl start rf-lab-ap rf-lab-dhcp || true
      for _ in $(seq 1 15); do systemctl is-active --quiet rf-lab-ap && break; sleep 1; done
      echo "AP restored after ~$(( $(date +%s) - start ))s"
    '';
  };

  tools = [ rfSweep rfCapture rfBtScan rfSim rfApOutage ];
in
{
  imports = [ ./ap.nix ./net-watchdog.nix ./bluetooth.nix ./hil.nix ];

  options.sam.rfLab = {
    enable = lib.mkEnableOption "2.4 GHz RF lab kit (naked-pi)";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages =
      (with pkgs; [ iw usbutils ethtool tcpdump bluez ]) ++ tools;

    systemd.tmpfiles.rules = [
      # Aged out so captures cannot fill the SD card silently.
      "d ${captureDir} 0750 ${username} users 14d"
    ];

    # Monitor mode needs CAP_NET_ADMIN and capture needs raw sockets, so the
    # operator would otherwise be root. Grant only these observation wrappers,
    # by their stable profile path (what `sudo rf-sweep` resolves to).
    security.sudo.extraRules = [
      {
        users = [ username ];
        commands = map (t: {
          command = "/run/current-system/sw/bin/${t.meta.mainProgram or t.name}";
          options = [ "NOPASSWD" ];
        }) tools;
      }
    ];
  };
}
