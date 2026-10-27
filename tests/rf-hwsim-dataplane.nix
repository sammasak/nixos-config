# Tests issue #40's claim that naked-pi's kernel 7.2.9 blocks the hwsim data
# plane, by running hwsim on a different nixpkgs kernel inside QEMU. Never loads
# hwsim on the host (lenovo is the k3s control plane). Rationale + verdict logic
# live in the commit/PR. Build: nix build .#packages.x86_64-linux.rf-hwsim-dataplane
{ pkgs }:
let
  # Two radios in SEPARATE netns so the peer IP traverses the radio, not
  # loopback; bare hwsim (no wmediumd) carries data in-kernel on a working kernel.
  phase1 = pkgs.writeShellScript "hwsim-phase1" ''
    set -euo pipefail
    echo "== phase1: plain hwsim, two netns (real over-the-radio data path) =="
    modprobe -r mac80211_hwsim 2>/dev/null || true
    modprobe mac80211_hwsim radios=2
    sleep 2
    ap=$(iw dev | awk '/Interface/{print $2}' | grep '^wlan' | sort | sed -n 1p)
    sta=$(iw dev | awk '/Interface/{print $2}' | grep '^wlan' | sort | sed -n 2p)
    apphy=$(cat "/sys/class/net/$ap/phy80211/name")
    staphy=$(cat "/sys/class/net/$sta/phy80211/name")
    echo "AP=$ap ($apphy)  STA=$sta ($staphy)"

    ip netns add apns
    ip netns add stans
    iw phy "$apphy" set netns name apns
    iw phy "$staphy" set netns name stans

    cat >/tmp/hostapd.conf <<EOF
    interface=$ap
    driver=nl80211
    ssid=vmsim
    hw_mode=g
    channel=1
    EOF
    ip netns exec apns hostapd -B /tmp/hostapd.conf
    ip netns exec apns ip addr add 10.77.0.1/24 dev "$ap"

    cat >/tmp/wpa.conf <<EOF
    ctrl_interface=/tmp/wpa_sta
    network={
      ssid="vmsim"
      key_mgmt=NONE
    }
    EOF
    ip netns exec stans wpa_supplicant -B -i "$sta" -c /tmp/wpa.conf

    assoc=no
    for _ in $(seq 1 30); do
      if ip netns exec stans iw dev "$sta" link | grep -qi "Connected to"; then assoc=yes; break; fi
      sleep 1
    done
    echo "association: $assoc"
    test "$assoc" = yes
    ip netns exec stans ip addr add 10.77.0.2/24 dev "$sta"
    sleep 1

    echo "== ping STA(10.77.0.2) -> AP(10.77.0.1) across the virtual radio =="
    ip netns exec stans ping -c 5 -W 3 10.77.0.1
    echo "PHASE1: data-plane PASS on kernel $(uname -r)"
  '';

  # Mirrors rf-sim's topology (both radios in one netns + wmediumd) for an
  # apples-to-apples comparison with the Pi. Reported, not asserted.
  phase2 = pkgs.writeShellScript "hwsim-phase2" ''
    set -uo pipefail
    echo "== phase2: single netns + wmediumd (rf-sim replica) =="
    modprobe -r mac80211_hwsim 2>/dev/null || true
    modprobe mac80211_hwsim radios=2
    sleep 2
    ns=lab
    ip netns add "$ns"
    w0=$(iw dev | awk '/Interface/{print $2}' | grep '^wlan' | sort | sed -n 1p)
    w1=$(iw dev | awk '/Interface/{print $2}' | grep '^wlan' | sort | sed -n 2p)
    p0=$(cat "/sys/class/net/$w0/phy80211/name")
    p1=$(cat "/sys/class/net/$w1/phy80211/name")
    iw phy "$p0" set netns name "$ns"
    iw phy "$p1" set netns name "$ns"
    apmac=$(ip netns exec "$ns" cat "/sys/class/net/$w0/address")
    stamac=$(ip netns exec "$ns" cat "/sys/class/net/$w1/address")

    cat >/tmp/wm.cfg <<EOF
    ifaces : { ids = ["$apmac", "$stamac"]; };
    model : { type = "prob"; default_prob = 0.0; };
    EOF
    ip netns exec "$ns" wmediumd -c /tmp/wm.cfg >/tmp/wmediumd.log 2>&1 &
    sleep 2
    echo "wmediumd log:"; sed 's/^/  /' /tmp/wmediumd.log || true

    cat >/tmp/hapd2.conf <<EOF
    interface=$w0
    driver=nl80211
    ssid=vmsim2
    hw_mode=g
    channel=1
    EOF
    ip netns exec "$ns" hostapd -B /tmp/hapd2.conf
    ip netns exec "$ns" ip addr add 10.78.0.1/24 dev "$w0"
    cat >/tmp/wpa2.conf <<EOF
    ctrl_interface=/tmp/wpa_sta2
    network={
      ssid="vmsim2"
      key_mgmt=NONE
    }
    EOF
    ip netns exec "$ns" wpa_supplicant -B -i "$w1" -c /tmp/wpa2.conf
    assoc=no
    for _ in $(seq 1 20); do
      if ip netns exec "$ns" iw dev "$w1" link | grep -qi "Connected to"; then assoc=yes; break; fi
      sleep 1
    done
    echo "association (wmediumd): $assoc"
    ip netns exec "$ns" ip addr add 10.78.0.2/24 dev "$w1"
    sleep 1
    if ip netns exec "$ns" ping -c 3 -W 3 10.78.0.1 >/tmp/ping2.log 2>&1; then
      echo "PHASE2: ping succeeded (NOTE: same-netns peer may resolve via loopback)"
    else
      echo "PHASE2: ping failed"
    fi
    sed 's/^/  /' /tmp/ping2.log || true
  '';
in
pkgs.testers.runNixOSTest {
  name = "rf-hwsim-dataplane";

  nodes.machine = {
    boot.kernelModules = [ "mac80211_hwsim" ];
    networking.wireless.enable = false;
    virtualisation.memorySize = 2048;
    environment.systemPackages = with pkgs; [
      iw
      iproute2
      hostapd
      wpa_supplicant
      wmediumd
      iperf3
      gawk
      gnugrep
    ];
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    kernel = machine.succeed("uname -r").strip()
    print("=== VM kernel:", kernel, "===")

    # Phase 1 asserts: machine.succeed aborts the test if assoc or ping fails.
    print(machine.succeed("${phase1}"))

    # Phase 2 is diagnostic: capture status + output without gating the test.
    status, out = machine.execute("${phase2}")
    print(out)
    print("=== phase2 exit status:", status, "===")

    machine.succeed("true")
  '';
}
