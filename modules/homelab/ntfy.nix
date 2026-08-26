# Self-hosted ntfy.sh notification server for the control plane.
# Runs outside k3s so it remains reachable even when the cluster is degraded.
# Accessible on the LAN and via Tailscale for push notifications to the mobile app.
{ config, lib, ... }:

with lib;

let
  cfg = config.homelab.ntfy;
in
{
  options.homelab.ntfy = {
    enable = mkEnableOption "ntfy.sh push notification server";

    port = mkOption {
      type = types.port;
      default = 2586;
      description = "TCP port to listen on.";
    };

    baseUrl = mkOption {
      type = types.str;
      description = "Public base URL clients use to reach this server (e.g. http://192.168.10.154:2586).";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Open the firewall port so LAN and Tailscale clients can reach ntfy.";
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
        behind-proxy = false;
      };
    };

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.port ];
  };
}
