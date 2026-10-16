# Owned-device Wi-Fi lab: naked-pi's onboard wlan0 as a WPA2 test AP on an
# isolated subnet (#37 workstream B). Opt-in and off by default; when enabled it
# is your own AP for your own clients — not a tool against anyone else's network.
# No bridge/NAT/route to the LAN: lab clients cannot reach the management subnet,
# and the AP runs on wlan0, never the Ethernet management path.
{ config, lib, pkgs, ... }:
let
  cfg = config.sam.rfLab.ap;
  runConf = "/run/rf-lab-ap/hostapd.conf";
  ctrl = "/run/rf-lab-ap/ctrl";
  enrolled = lib.concatStringsSep " " (map lib.toLower cfg.enrolledStations);

  # Evict a station from OUR OWN AP via hostapd's control socket — the sanctioned
  # AP-admin path (#38), not frame injection. Refuses any MAC not in the enrolled
  # allowlist and any MAC not currently associated to our AP, so it structurally
  # cannot touch a third-party device or a station on anyone else's network.
  rfApKick = pkgs.writeShellApplication {
    name = "rf-ap-kick";
    runtimeInputs = with pkgs; [ hostapd gnugrep coreutils ];
    text = ''
      mac=$(printf '%s' "''${1:?usage: rf-ap-kick <enrolled-MAC> [--commit]}" | tr '[:upper:]' '[:lower:]')
      commit=''${2:-}
      enrolled="${enrolled}"
      case " $enrolled " in *" $mac "*) ;; *) echo "refused: $mac not in enrolledStations" >&2; exit 1 ;; esac
      hc() { hostapd_cli -p ${ctrl} -i ${cfg.interface} "$@"; }
      if ! hc all_sta 2>/dev/null | grep -qi "^$mac$"; then
        echo "refused: $mac is not currently associated to our AP (${cfg.ssid})" >&2
        exit 1
      fi
      if [ "$commit" != "--commit" ]; then
        printf '{"station":"%s","action":"deauthenticate","mode":"dry-run","associated":true}\n' "$mac"
        exit 0
      fi
      out=$(hc deauthenticate "$mac" 2>&1 || true)
      printf '{"station":"%s","action":"deauthenticate","mode":"commit","result":"%s"}\n' "$mac" "$out"
    '';
  };

  rfApStatus = pkgs.writeShellApplication {
    name = "rf-ap-status";
    runtimeInputs = with pkgs; [ hostapd coreutils ];
    text = ''
      if ! hostapd_cli -p ${ctrl} -i ${cfg.interface} ping >/dev/null 2>&1; then
        echo "lab AP not running (sam.rfLab.ap.enable=false?)" >&2; exit 1
      fi
      echo "== stations associated to ${cfg.ssid} (${cfg.interface}):"
      hostapd_cli -p ${ctrl} -i ${cfg.interface} all_sta
    '';
  };
  apTools = [ rfApKick rfApStatus ];
in
{
  options.sam.rfLab.ap = {
    enable = lib.mkEnableOption "owned WPA2 test AP on an isolated subnet (wlan0)";

    ssid = lib.mkOption {
      type = lib.types.str;
      default = "naked-lab";
      description = "Test SSID broadcast by the lab AP.";
    };

    channel = lib.mkOption {
      type = lib.types.ints.between 1 13;
      default = 6;
      description = "2.4 GHz channel for the lab AP.";
    };

    interface = lib.mkOption {
      type = lib.types.str;
      default = "wlan0";
      description = "AP-capable radio (onboard wlan0; never the Ethernet NIC).";
    };

    gateway = lib.mkOption {
      type = lib.types.str;
      default = "10.77.0.1";
      description = "AP IPv4 on the isolated lab subnet (a /24 is assumed).";
    };

    dhcpRange = lib.mkOption {
      type = lib.types.str;
      default = "10.77.0.50,10.77.0.150,1h";
      description = "dnsmasq dhcp-range for the lab subnet (DHCP only; DNS off).";
    };

    pskFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        File holding the WPA2 passphrase (one line), e.g. a sops-nix secret path.
        Loaded as a systemd credential, so it never enters the Nix store. Required
        when the AP is enabled.
      '';
    };

    enrolledStations = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Lower/upper-case MACs of your own test clients that rf-ap-kick may evict
        from this AP. A MAC not in this list is refused; eviction also requires
        the station to be currently associated to our AP.
      '';
    };
  };

  config = lib.mkIf (config.sam.rfLab.enable && cfg.enable) {
    assertions = [
      {
        assertion = cfg.pskFile != null;
        message = "sam.rfLab.ap.pskFile must be set (WPA2 passphrase, ideally a sops secret) when the AP lab is enabled.";
      }
    ];

    environment.systemPackages = (with pkgs; [ hostapd dnsmasq ]) ++ apTools;

    # hostapd_cli on the control socket needs root; grant lukas only these two
    # observation/eviction wrappers, each gated to our own AP's enrolled stations.
    security.sudo.extraRules = [
      {
        users = [ config.sam.profile.username ];
        commands = map (t: {
          command = "/run/current-system/sw/bin/${t.meta.mainProgram or t.name}";
          options = [ "NOPASSWD" ];
        }) apTools;
      }
    ];

    # The passphrase is assembled into the runtime conf under /run by ExecStartPre,
    # so it is never world-readable and never in the store.
    systemd.services.rf-lab-ap = {
      description = "rf-lab owned WPA2 test AP (hostapd)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        LoadCredential = [ "psk:${toString cfg.pskFile}" ];
        RuntimeDirectory = "rf-lab-ap";
        RuntimeDirectoryMode = "0700";
        ExecStartPre = pkgs.writeShellScript "rf-lab-ap-pre" ''
          ${pkgs.iproute2}/bin/ip addr flush dev ${cfg.interface} || true
          ${pkgs.iproute2}/bin/ip addr add ${cfg.gateway}/24 dev ${cfg.interface} || true
          umask 077
          {
            echo "interface=${cfg.interface}"
            echo "driver=nl80211"
            echo "ssid=${cfg.ssid}"
            echo "hw_mode=g"
            echo "channel=${toString cfg.channel}"
            echo "wpa=2"
            echo "wpa_key_mgmt=WPA-PSK"
            echo "rsn_pairwise=CCMP"
            echo "ctrl_interface=${ctrl}"
            echo "wpa_passphrase=$(cat "$CREDENTIALS_DIRECTORY/psk")"
          } > ${runConf}
        '';
        ExecStart = "${pkgs.hostapd}/bin/hostapd ${runConf}";
        Restart = "on-failure";
      };
    };

    # DHCP only (port=0 disables DNS), bound to the lab interface alone.
    systemd.services.rf-lab-dhcp = {
      description = "rf-lab DHCP for the isolated lab subnet (dnsmasq)";
      wantedBy = [ "multi-user.target" ];
      after = [ "rf-lab-ap.service" ];
      serviceConfig.ExecStart =
        "${pkgs.dnsmasq}/bin/dnsmasq --keep-in-foreground --port=0 "
        + "--interface=${cfg.interface} --bind-interfaces "
        + "--dhcp-range=${cfg.dhcpRange} --dhcp-authoritative";
    };

    # Scoped, not global: only DHCP reaches the AP, and only on the lab interface.
    # SSH stays LAN-only (lib/firewall.nix), so lab clients (10.77.0.0/24) cannot
    # reach it, and with no forwarding/NAT they cannot reach the management subnet.
    networking.firewall.interfaces.${cfg.interface}.allowedUDPPorts = [ 67 ];
  };
}
