# Opt-in passive 2.4 GHz observation kit for naked-pi. Capture and standard
# discovery only — no injection, deauth, jamming or AP mode in any wrapper.
# Driven from lenovo by the `rf:*` devenv tasks (see devenv.nix); full context
# in modules/rf-lab/README.md and ~/knowledge/homelab/runbooks/naked-pi-rf-lab.md.
{ config, lib, pkgs, ... }:
let
  cfg = config.sam.rfLab;
  username = config.sam.profile.username;

  # The USB adapter is the only monitor-capable radio (onboard is 2.4 GHz
  # managed-only). Find it by its udev USB name (wlu*), which is stable — unlike
  # the phy index, which flips with USB enumeration order across boots.
  pickMon = ''
    IF=$(iw dev | awk '/Interface/{print $2}' | grep -m1 '^wlu' || true)
    if [ -z "''${IF:-}" ]; then
      # The rtl8192cu RX path wedges after repeated mode flips or an undervoltage
      # USB brownout; one module reload clears the soft cases, a replug the rest.
      modprobe -r rtl8192cu 2>/dev/null || true; sleep 1
      modprobe rtl8192cu 2>/dev/null || true; sleep 3
      IF=$(iw dev | awk '/Interface/{print $2}' | grep -m1 '^wlu' || true)
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
    runtimeInputs = with pkgs; [ iw tcpdump coreutils gawk kmod ];
    text = ''
      per=''${1:-1.2}
      ${pickMon}
      out="${cfg.captureDir}/sweep-$(date +%Y%m%dT%H%M%S).pcap"
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
    runtimeInputs = with pkgs; [ iw tcpdump coreutils gawk kmod ];
    text = ''
      ch=''${1:?usage: rf-capture <channel> [seconds] [bpf-filter]}
      secs=''${2:-30}
      filter=''${3:-}
      ${pickMon}
      out="${cfg.captureDir}/capture-ch''${ch}-$(date +%Y%m%dT%H%M%S).pcap"
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
    runtimeInputs = with pkgs; [ kmod iw iproute2 hostapd wpa_supplicant wmediumd iperf3 coreutils gnugrep ];
    text = ''
      ns=rfsim
      loss=''${RF_LOSS:-0.0}     # wmediumd per-frame loss probability (0.0 = perfect)
      outage=''${RF_OUTAGE:-1}   # seconds the station stays disconnected
      tmp=$(mktemp -d)
      cleanup() {
        ip netns pids "$ns" 2>/dev/null | xargs -r kill 2>/dev/null || true
        ip netns del "$ns" 2>/dev/null || true
        modprobe -r mac80211_hwsim 2>/dev/null || true
        rm -rf "$tmp"
      }
      trap cleanup EXIT
      modprobe -r mac80211_hwsim 2>/dev/null || true

      # shellcheck disable=SC2012
      before=$(ls /sys/class/ieee80211 2>/dev/null | sort)
      modprobe mac80211_hwsim radios=2
      sleep 1
      # shellcheck disable=SC2012
      after=$(ls /sys/class/ieee80211 2>/dev/null | sort)
      newphys=$(comm -13 <(echo "$before") <(echo "$after"))
      ip netns add "$ns"
      for p in $newphys; do iw phy "$p" set netns name "$ns" 2>/dev/null || true; done

      mapfile -t ifs < <(ip netns exec "$ns" sh -c 'ls /sys/class/net | grep "^wlan"')
      if [ "''${#ifs[@]}" -lt 2 ]; then echo "hwsim did not yield two radios" >&2; exit 1; fi
      ap=''${ifs[0]}; sta=''${ifs[1]}
      apmac=$(ip netns exec "$ns" cat "/sys/class/net/$ap/address")
      stamac=$(ip netns exec "$ns" cat "/sys/class/net/$sta/address")
      echo "virtual radios: AP=$ap STA=$sta (netns $ns)"

      # wmediumd mediates the virtual medium so data frames (not just assoc) flow;
      # default_prob 0.0 is a perfect link — raise it to model loss for chaos.
      cat >"$tmp/wm.cfg" <<EOF
      ifaces : { ids = ["$apmac", "$stamac"]; };
      model : { type = "prob"; default_prob = $loss; };
      EOF
      ip netns exec "$ns" wmediumd -c "$tmp/wm.cfg" >/dev/null 2>&1 &
      sleep 1

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

      # hostapd/wpa_supplicant bring their own interfaces up; pre-upping the AP
      # makes nl80211 fail to set AP mode ("Could not configure driver mode").
      ip netns exec "$ns" hostapd -B "$tmp/hostapd.conf" >/dev/null 2>&1 || { echo "hostapd failed to start" >&2; exit 1; }
      ip netns exec "$ns" ip addr add 10.77.0.1/24 dev "$ap" 2>/dev/null || true
      ip netns exec "$ns" wpa_supplicant -B -i "$sta" -c "$tmp/wpa.conf" >/dev/null 2>&1 || true

      assoc=no
      for _ in $(seq 1 15); do
        if ip netns exec "$ns" iw dev "$sta" link 2>/dev/null | grep -qi "Connected to"; then assoc=yes; break; fi
        sleep 1
      done
      echo "association: $assoc"
      [ "$assoc" = yes ] || { echo "station did not associate" >&2; exit 1; }
      ip netns exec "$ns" ip addr add 10.77.0.2/24 dev "$sta" 2>/dev/null || true
      sleep 1

      echo "== iperf3 (virtual link via wmediumd, 3s):"
      ip netns exec "$ns" iperf3 -s -1 -D >/dev/null 2>&1 || true
      sleep 1
      ip netns exec "$ns" iperf3 -c 10.77.0.1 -t 3 2>/dev/null | grep -E "sender|receiver" \
        || echo "  no data plane: hwsim passes assoc but not data frames on kernel $(uname -r), even with wmediumd (see #40)"

      # Chaos/recovery: drop the station from its own AP, hold the outage, time recovery.
      echo "== disconnect/reconnect (outage ''${outage}s):"
      start=$(date +%s)
      ip netns exec "$ns" wpa_cli -i "$sta" -p "$tmp/wpa" disconnect >/dev/null 2>&1 || true
      sleep "$outage"
      ip netns exec "$ns" wpa_cli -i "$sta" -p "$tmp/wpa" reconnect >/dev/null 2>&1 || true
      recovered=timeout
      for _ in $(seq 1 15); do
        if ip netns exec "$ns" iw dev "$sta" link 2>/dev/null | grep -qi "Connected to"; then recovered=$(( $(date +%s) - start )); break; fi
        sleep 1
      done
      echo "  reassociated in ~''${recovered}s"

      # Deterministic artifact (simulation only — not a hardware measurement).
      dp=blocked
      printf '{"kind":"simulation","scenario":{"loss":%s,"outage_s":%s},"association":"%s","reassociated_s":"%s","data_plane":"%s","kernel":"%s"}\n' \
        "$loss" "$outage" "$assoc" "$recovered" "$dp" "$(uname -r)"
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
  imports = [ ./ap.nix ./net-watchdog.nix ./bluetooth.nix ];

  options.sam.rfLab = {
    enable = lib.mkEnableOption "passive 2.4 GHz RF observation kit (naked-pi)";

    captureDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/rf-lab/captures";
      description = "Directory for PCAPs; kept off the Nix store and aged out.";
    };

    retentionDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 14;
      description = "Days before a capture is deleted, so the SD card cannot fill silently.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages =
      (with pkgs; [ iw usbutils ethtool tcpdump bluez ]) ++ tools;

    systemd.tmpfiles.rules = [
      "d ${cfg.captureDir} 0750 ${username} users ${toString cfg.retentionDays}d"
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
