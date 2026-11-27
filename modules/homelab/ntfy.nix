# Self-hosted ntfy.sh notification server for the control plane.
# Runs on lenovo, beside AdGuard, so it stays reachable when the other hosts are down.
# Accessible on the LAN and via Tailscale for push notifications to the mobile app.
{ config, lib, ... }:

let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;
  cfg = config.homelab.ntfy;
in
{
  options.homelab.ntfy = {
    enable = mkEnableOption "ntfy.sh push notification server";

    port = mkOption {
      type = types.port;
      default = config.sam.fleet.ntfy.port;
      defaultText = lib.literalExpression "config.sam.fleet.ntfy.port";
      description = "TCP port to listen on.";
    };

    baseUrl = mkOption {
      type = types.str;
      description = "Public base URL clients use to reach this server (e.g. https://ntfy.sammasak.dev).";
    };
  };

  config = mkIf cfg.enable {
    services.ntfy-sh = {
      enable = true;
      settings = {
        base-url = cfg.baseUrl;
        listen-http = ":${toString cfg.port}";
        cache-file = "/var/lib/ntfy-sh/cache.db";
        attachment-cache-dir = "/var/lib/ntfy-sh/attachments";
        # Open read-write access: fine for a LAN/Tailscale-only homelab instance.
        auth-default-access = "read-write";
        # Caddy on acer proxies ntfy.sammasak.dev (edge.nix); a LAN client can spoof only its rate-limit key.
        behind-proxy = true;
        # A per-alert receipt in Loki: message_delayed is a field of the publish handler's "Received message" event
        # alone, whose trace form carries the message JSON (topic, title). Overrides match one field, so a topic
        # key would also trace that topic's keepalives and stats. json keeps the indented body on one journal line.
        log-format = "json";
        log-level-overrides = [ "message_delayed -> trace" ];
      };
    };

    systemd.services.ntfy-sh = {
      # never gives up: nothing can report this unit failed, since the alerts go through it
      startLimitIntervalSec = 0;
      serviceConfig = {
        Restart = "always";
        RestartSec = 5;
        RestartSteps = 5;
        RestartMaxDelaySec = "5min";
      };
    };

    networking.firewall.allowedTCPPorts = [ cfg.port ];

    assertions = [
      {
        assertion = config.networking.hostName == config.sam.fleet.ntfy.host;
        message = "modules/homelab/ntfy.nix runs on ${config.networking.hostName}, but sam.fleet.ntfy.host is ${config.sam.fleet.ntfy.host}: every page would go to the wrong host.";
      }
      {
        assertion = cfg.port == config.sam.fleet.ntfy.port;
        message = "homelab.ntfy.port ${toString cfg.port} is not sam.fleet.ntfy.port ${toString config.sam.fleet.ntfy.port}: every page would go to the wrong port.";
      }
    ];
  };
}
