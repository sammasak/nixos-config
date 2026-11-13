# Alertmanager webhook to ntfy bridge (sammasak/alert-bridge). Runs beside ntfy,
# outside k3s, so a page does not depend on the cluster it reports on.
{ config, lib, pkgs, ... }:

let
  inherit (lib) getExe mkEnableOption mkIf mkOption mkPackageOption types;
  inherit (import ../../lib/firewall.nix lib) mkDualBackendFirewall;
  cfg = config.homelab.alertBridge;

  healthUrl = "http://${if cfg.listenAddress == "0.0.0.0" then "127.0.0.1" else cfg.listenAddress}:${toString cfg.port}/health";

  firewallRules = mkDualBackendFirewall {
    nftComment = "alert-bridge: Alertmanager, from its pod or from its node.";
    ports = [ cfg.port ];
    sources = [
      config.sam.profile.lanCidr
      "10.42.0.0/16" # k3s pod CIDR
    ];
    interfaces = [ ];
    backend = config.networking.firewall.backend;
  };
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
      type = types.str;
      default = "http://127.0.0.1:${toString config.homelab.ntfy.port}/homelab-alerts";
      defaultText = "http://127.0.0.1:<ntfy.port>/homelab-alerts";
      description = "ntfy topic URL pages are published to. Plain http only: the bridge has no TLS stack.";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Accept the port from the LAN and the k3s pod network.";
    };
  };

  config = mkIf cfg.enable {
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
        # Type=exec is "started" before the bind; without this probe a bridge
        # that cannot listen passes a switch and then restarts forever.
        ExecStartPost = "${getExe pkgs.curl} --fail --silent --show-error --output /dev/null --max-time 5 --retry 10 --retry-delay 1 --retry-connrefused ${healthUrl}";
        Restart = "always";
        RestartSec = 5;
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
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
        UMask = "0077";
      };
    };

    networking.firewall = mkIf cfg.openFirewall {
      inherit (firewallRules) extraInputRules extraCommands;
    };
  };
}
