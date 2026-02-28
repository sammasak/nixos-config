# Tailscale subnet router configuration for homelab
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.homelab.tailscale;
in
{
  options.homelab.tailscale = {
    enable = mkEnableOption "Tailscale subnet router";

    subnetRoutes = mkOption {
      type = types.listOf types.str;
      default = [ config.sam.profile.lanCidr ];
      description = "List of subnet routes to advertise";
    };

    authKeyFile = mkOption {
      type = types.path;
      default = "/run/secrets/tailscale-authkey";
      description = "Path to the Tailscale authkey file (SOPS-encrypted)";
    };
  };

  config = mkIf cfg.enable {
    # Enable Tailscale service
    services.tailscale = {
      enable = true;
      useRoutingFeatures = "server";  # Enable subnet routing
    };

    # Systemd service to configure Tailscale as subnet router
    systemd.services.tailscale-subnet-router = {
      description = "Configure Tailscale as subnet router";
      after = [ "network-online.target" "tailscaled.service" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        # Wait for tailscaled to be ready
        while ! ${pkgs.tailscale}/bin/tailscale status &>/dev/null; do
          echo "Waiting for tailscaled to start..."
          sleep 2
        done

        # Check if already authenticated
        if ! ${pkgs.tailscale}/bin/tailscale status --json | ${pkgs.jq}/bin/jq -e '.Self.Online' &>/dev/null; then
          echo "Authenticating with Tailscale..."
          ${pkgs.tailscale}/bin/tailscale up \
            --authkey=file:${cfg.authKeyFile} \
            --advertise-routes=${concatStringsSep "," cfg.subnetRoutes} \
            --accept-routes \
            --ssh
        else
          echo "Already authenticated. Updating subnet routes..."
          ${pkgs.tailscale}/bin/tailscale up \
            --advertise-routes=${concatStringsSep "," cfg.subnetRoutes} \
            --accept-routes \
            --ssh
        fi
      '';
    };

    # Enable IP forwarding for subnet routing
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv6.conf.all.forwarding" = 1;
    };

    # Firewall rules for Tailscale
    networking.firewall = {
      # Allow Tailscale traffic
      trustedInterfaces = [ "tailscale0" ];

      # Allow UDP for Tailscale (41641 is the default)
      allowedUDPPorts = [ config.services.tailscale.port ];
    };
  };
}
