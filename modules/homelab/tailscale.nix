# Tailscale for the homelab.
#
# Two modes, because the two node classes want different things from the tailnet:
#
#   * "subnet-router" (control plane) — advertises the LAN CIDR into the tailnet
#     and enables Tailscale SSH. This is what makes every box on the LAN
#     reachable from outside through a single node.
#
#   * "client" (workers) — plain tailnet membership, nothing more. The point is
#     that the node keeps its own remote-access path when the subnet router is
#     down; without it, losing the control plane also loses the only way to
#     reach the worker. Deliberately restrained:
#       - no advertised routes: the worker is already on the LAN;
#       - --accept-routes=false: accepting the router's LAN CIDR on a host that
#         sits inside that subnet would push its own LAN traffic back through
#         the control plane, recreating the very dependency this removes;
#       - --accept-dns=false: MagicDNS would rewrite /etc/resolv.conf to the
#         control plane's AdGuard — same coupling, plus it disturbs the
#         resolver on a k3s node;
#       - no --ssh: sshd and its hardening stay the only shell boundary.
{ config, lib, pkgs, ... }:

let
  inherit (lib) concatStringsSep escapeShellArgs mkDefault mkEnableOption mkIf mkOption types;
  cfg = config.homelab.tailscale;
  isSubnetRouter = cfg.mode == "subnet-router";

  modeFlags =
    if isSubnetRouter then
      [
        "--advertise-routes=${concatStringsSep "," cfg.subnetRoutes}"
        "--accept-routes"
        "--ssh"
      ]
    else
      [
        "--accept-routes=false"
        "--accept-dns=false"
      ];
in
{
  options.homelab.tailscale = {
    enable = mkEnableOption "Tailscale";

    mode = mkOption {
      type = types.enum [ "subnet-router" "client" ];
      default = "subnet-router";
      description = ''
        "subnet-router" advertises `subnetRoutes` into the tailnet and enables
        Tailscale SSH. "client" only joins the tailnet: no routes advertised,
        none accepted, no MagicDNS takeover and no Tailscale SSH.
      '';
    };

    subnetRoutes = mkOption {
      type = types.listOf types.str;
      default = [ config.sam.profile.lanCidr ];
      description = ''List of subnet routes to advertise (mode = "subnet-router" only).'';
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
      useRoutingFeatures = if isSubnetRouter then "server" else "client";
    };

    # Systemd service that joins the tailnet with this node's mode-specific prefs.
    systemd.services.tailscale-autoconnect = {
      description = "Join the Tailscale tailnet (mode: ${cfg.mode})";
      after = [ "network-online.target" "tailscaled.service" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # A wedged tailscaled must not leave this unit stuck in "activating".
        TimeoutStartSec = "5min";
      };

      script = ''
        # Wait for tailscaled to be ready (bounded — see TimeoutStartSec).
        for _ in $(seq 1 60); do
          ${pkgs.tailscale}/bin/tailscale status &>/dev/null && break
          echo "Waiting for tailscaled to start..."
          sleep 2
        done

        upFlags=( ${escapeShellArgs modeFlags} )

        # Only pass the authkey when this node is not authenticated yet:
        # re-running `tailscale up` with an already-consumed single-use key fails.
        if ! ${pkgs.tailscale}/bin/tailscale status --json | ${pkgs.jq}/bin/jq -e '.Self.Online' &>/dev/null; then
          echo "Authenticating with Tailscale..."
          upFlags+=( --authkey=file:${cfg.authKeyFile} )
        else
          echo "Already authenticated. Reapplying preferences..."
        fi

        if ! ${pkgs.tailscale}/bin/tailscale up "''${upFlags[@]}"; then
          echo "tailscale up failed. The likeliest cause is that the authkey in" >&2
          echo "${cfg.authKeyFile} has expired, or was single-use and is already" >&2
          echo "consumed. Mint a fresh key in the Tailscale admin console, update" >&2
          echo "secrets/homelab/tailscale.yaml, rebuild, then run:" >&2
          echo "  systemctl start tailscale-autoconnect" >&2
          exit 1
        fi
      '';
    };

    # IP forwarding is only needed when this node routes on behalf of others.
    boot.kernel.sysctl = mkIf isSubnetRouter {
      "net.ipv4.ip_forward" = mkDefault 1;
      "net.ipv6.conf.all.forwarding" = mkDefault 1;
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
