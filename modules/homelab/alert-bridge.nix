# Alertmanager webhook to ntfy bridge (sammasak/alert-bridge). Runs beside ntfy on lenovo, so a page does not
# depend on the host that runs Alertmanager.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    getExe
    mkEnableOption
    mkIf
    mkOption
    mkPackageOption
    types
    ;
  cfg = config.homelab.alertBridge;
  listener = config.sam.fleet.listeners.alert-bridge;
  # the firewall admits it from here (modules/core/network.nix)
  served = listener.host == config.networking.hostName;

  healthUrl = "http://${
    if cfg.listenAddress == "0.0.0.0" then "127.0.0.1" else cfg.listenAddress
  }:${toString cfg.port}/health";

  # the listener's callers, the firewall's sources too; the unit's IP filter holds them on trusted interfaces as well
  # (lenovo trusts tailscale0). Any other source could page homelab-alerts; flake-modules/alert-bridge-check.nix ties
  # this to the Alertmanager host.
  admitted = lib.concatMap (
    h: [ config.sam.fleet.hosts.${h}.address ] ++ config.sam.fleet.hosts.${h}.extraAddresses
  ) listener.from;
in
{
  # ntfy.nix: so the `ntfyUrl` default can read homelab.ntfy.port on hosts
  # that do not otherwise import it.
  imports = [ ./ntfy.nix ];

  options.homelab.alertBridge = {
    enable = mkEnableOption "Alertmanager webhook to ntfy bridge";

    package = mkPackageOption pkgs "alertBridge" { };

    listenAddress = mkOption {
      type = types.strMatching "[0-9]+(\\.[0-9]+){3}";
      default = "127.0.0.1";
      description = "IPv4 address to listen on.";
    };

    port = mkOption {
      type = types.port;
      default = 9099;
      description = "TCP port to listen on.";
    };

    ntfyUrl = mkOption {
      type = types.strMatching "http://.+";
      default = "http://127.0.0.1:${toString config.homelab.ntfy.port}/homelab-alerts";
      defaultText = "http://127.0.0.1:<ntfy.port>/homelab-alerts";
      description = "ntfy topic URL pages are published to. Plain http only: the bridge has no TLS stack.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = served -> !lib.hasPrefix "127." cfg.listenAddress;
        message = "homelab.alertBridge: sam.fleet.listeners.alert-bridge is served here, but listenAddress ${cfg.listenAddress} is loopback, so nothing the firewall admits can reach the bridge.";
      }
      {
        assertion =
          (served -> cfg.port == listener.port)
          && (config.systemd.services.alert-bridge.serviceConfig.IPAddressDeny or null) == "any"
          &&
            (config.systemd.services.alert-bridge.serviceConfig.IPAddressAllow or null)
            == admitted ++ [ "localhost" ];
        message = "homelab.alertBridge: listen on sam.fleet.listeners.alert-bridge's port ${toString listener.port}, and keep the unit's IPAddressDeny = any with IPAddressAllow = ${toString admitted} localhost: only the Alertmanager host may page, from the LAN or a trusted interface.";
      }
      {
        # IPAddressDeny = any holds outgoing traffic too: a publish anywhere but loopback is dropped without a page
        assertion = builtins.match "http://(127[.][0-9.]+|localhost)(:[0-9]+)?/.*" cfg.ntfyUrl != null;
        message = "homelab.alertBridge.ntfyUrl ${cfg.ntfyUrl} is not loopback; the unit's IP filter only lets it reach localhost and black-pi.";
      }
      {
        assertion = config.homelab.ntfy.enable;
        message = "homelab.alertBridge publishes to this host's ntfy, which needs homelab.ntfy.enable.";
      }
    ];

    systemd.services.alert-bridge = {
      description = "Alertmanager webhook to ntfy bridge";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      environment = {
        ALERT_BRIDGE_LISTEN = "${cfg.listenAddress}:${toString cfg.port}";
        ALERT_BRIDGE_NTFY_URL = cfg.ntfyUrl;
      };
      serviceConfig = {
        Type = "exec";
        ExecStart = getExe cfg.package;
        # localhost: the start probe and ntfy
        IPAddressAllow = admitted ++ [ "localhost" ];
        IPAddressDeny = "any";
        # Type=exec is "started" before the bind; without this probe a bridge
        # that cannot listen passes a switch and then restarts forever.
        ExecStartPost = "${getExe pkgs.curl} --fail --silent --show-error --output /dev/null --max-time 5 --retry 10 --retry-delay 1 --retry-connrefused ${healthUrl}";
        Restart = "always";
        RestartSec = 5;
        # Reachable from the LAN, on the DNS host: a flood of requests ends in
        # a restart of the bridge, not in pressure on AdGuard and ntfy.
        MemoryMax = "64M";
        TasksMax = 64;
        LimitNOFILE = 256;
        DynamicUser = true;
        CapabilityBoundingSet = "";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        PrivateUsers = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
          "~@resources"
        ];
        UMask = "0077";
      };
    };
  };
}
