# Opt-in passive 2.4 GHz observation kit for naked-pi. Capture and standard
# discovery only — no injection, deauth, jamming or AP mode in any wrapper.
# Driven from lenovo by the `rf:*` devenv tasks (see devenv.nix); full context
# in modules/rf-lab/README.md and ~/knowledge/homelab/runbooks/naked-pi-rf-lab.md.
{ config, lib, pkgs, ... }:
let
  cfg = config.sam.rfLab;
  username = config.sam.profile.username;

  # The USB adapter is the only monitor-capable radio (onboard wlan0 is managed/
  # AP only), so pick its interface by phy; a kernel rename then cannot break it.
  pickMon = ''
    IF=$(iw dev | awk -v p="phy#${toString cfg.monitorPhy}" '$0~p{f=1} f&&/Interface/{print $2; exit}')
    if [ -z "''${IF:-}" ]; then
      # The rtl8192cu RX path wedges after repeated mode flips or an undervoltage
      # USB brownout; one module reload clears the soft cases, a replug the rest.
      modprobe -r rtl8192cu 2>/dev/null || true; sleep 1
      modprobe rtl8192cu 2>/dev/null || true; sleep 3
      IF=$(iw dev | awk -v p="phy#${toString cfg.monitorPhy}" '$0~p{f=1} f&&/Interface/{print $2; exit}')
    fi
    if [ -z "''${IF:-}" ]; then
      echo "no monitor-capable radio on phy#${toString cfg.monitorPhy}; replug the USB adapter (see runbook)" >&2
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

  tools = [ rfSweep rfCapture rfBtScan ];
in
{
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

    monitorPhy = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 1;
      description = "phy index of the USB monitor-capable adapter (onboard wlan0 is phy0).";
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
