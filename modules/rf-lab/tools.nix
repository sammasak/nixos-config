# Passive 2.4 GHz observation helpers for naked-pi. Capture and standard
# discovery only — no injection, deauth or AP mode anywhere in these scripts.
# Driven from lenovo by the `rf:*` devenv tasks (see devenv.nix).
{ config, lib, pkgs, ... }:
let
  username = config.sam.profile.username;
  captureDir = "/var/lib/rf-lab/captures";

  # The USB adapter is the only monitor-capable radio (onboard wlan0 is managed-
  # only), so pick its interface by phy; a kernel rename then does not break the kit.
  pickMon = ''
    IF=$(iw dev | awk '/phy#1/{f=1} f&&/Interface/{print $2; exit}')
    if [ -z "''${IF:-}" ]; then
      echo "no monitor-capable radio on phy#1 (is the USB adapter plugged in?)" >&2
      exit 1
    fi
  '';

  # Undervoltage drops the adapter off the USB bus mid-run, so every radio op is
  # best-effort and the trap always hands the radio back to managed mode.
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

  rfSweep = pkgs.writeShellApplication {
    name = "rf-sweep";
    runtimeInputs = with pkgs; [ iw tcpdump coreutils gawk ];
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
      echo "$out"
    '';
  };

  rfCapture = pkgs.writeShellApplication {
    name = "rf-capture";
    runtimeInputs = with pkgs; [ iw tcpdump coreutils ];
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
      echo "$out"
    '';
  };

  rfBtScan = pkgs.writeShellApplication {
    name = "rf-btscan";
    runtimeInputs = with pkgs; [ bluez coreutils ];
    text = ''
      secs=''${1:-15}
      if ! bluetoothctl show >/dev/null 2>&1; then
        echo "bluetooth controller unavailable (hci0 down; see undervoltage note in runbook)" >&2
        exit 1
      fi
      bluetoothctl --timeout "$secs" scan on >/dev/null 2>&1 || true
      bluetoothctl devices
    '';
  };

  tools = [ rfSweep rfCapture rfBtScan ];
in
{
  environment.systemPackages =
    (with pkgs; [ iw usbutils ethtool tcpdump bluez ]) ++ tools;

  # Monitor mode needs CAP_NET_ADMIN and capture needs raw sockets, so the
  # operator would otherwise be root. Grant only these three observation
  # wrappers, by their stable profile path (what `sudo rf-sweep` resolves to).
  security.sudo.extraRules = [
    {
      users = [ username ];
      commands = map (t: {
        command = "/run/current-system/sw/bin/${t.meta.mainProgram or t.name}";
        options = [ "NOPASSWD" ];
      }) tools;
    }
  ];
}
