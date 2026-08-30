# Tailscale for the homelab, in two modes.
#
# "subnet-router" (control plane) advertises the LAN CIDR, which is what makes
# every box on the LAN reachable from outside through a single node.
#
# "client" is plain tailnet membership with everything else refused — no routes
# advertised or accepted, no MagicDNS, no Tailscale SSH — so that a node using
# it gains a remote-access path without routing its own LAN traffic back
# through the control plane. No host currently selects it; workers run no
# client at all (see CLAUDE.md, Tailscale Remote Access).
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
  # sops.nix: so `authKeyFile` can point at the declared secret instead of
  # repeating its path; the config block below turns homelab.secrets on.
  # ntfy.nix: so the `ntfyUrl` default can read homelab.ntfy.port on hosts
  # that never import the ntfy module themselves.
  imports = [ ./sops.nix ./ntfy.nix ];

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
      default = config.sops.secrets."tailscale/authkey".path;
      defaultText = ''config.sops.secrets."tailscale/authkey".path'';
      description = "Path to the Tailscale authkey file (SOPS-encrypted)";
    };

    ntfyUrl = mkOption {
      type = types.str;
      default = "http://localhost:${toString config.homelab.ntfy.port}/homelab-alerts";
      defaultText = "http://localhost:<ntfy.port>/homelab-alerts";
      description = "ntfy push URL paged when tailnet auth needs an operator.";
    };
  };

  config = mkIf cfg.enable {
    # Declares the tailscale/authkey secret that authKeyFile defaults to.
    homelab.secrets.enable = true;

    services.tailscale = {
      enable = true;
      useRoutingFeatures = if isSubnetRouter then "server" else "client";
    };

    systemd.services.tailscale-autoconnect = {
      description = "Join the Tailscale tailnet (mode: ${cfg.mode})";
      after = [ "network-online.target" "tailscaled.service" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      # Without this, a switch restarts the unit and a dead authkey or pending
      # re-auth fails the WHOLE activation (exit 4 → the rebuild trigger rolls
      # back), holding every deploy hostage to tailnet auth state. Unit changes
      # apply on next boot or a manual `systemctl restart tailscale-autoconnect`
      # — restart, not start: RemainAfterExit leaves the unit active, and start
      # on an active unit is a no-op.
      restartIfChanged = false;

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # A wedged tailscaled must not leave this unit stuck in "activating".
        TimeoutStartSec = "5min";
      };

      script = ''
        # Wait for tailscaled's LocalAPI (bounded — see TimeoutStartSec).
        # --json: the plain form exits 1 while merely logged out, which reads
        # as "daemon not up" and burns the whole loop before every re-auth.
        for _ in $(seq 1 60); do
          ${pkgs.tailscale}/bin/tailscale status --json &>/dev/null && break
          echo "Waiting for tailscaled to start..."
          sleep 2
        done

        # The LocalAPI answers before the control round trip that mints an
        # AuthURL on node-key expiry; snapshotting too early misses the URL and
        # the stored key then stomps the pending re-auth. Wait for the backend
        # to settle, and give NeedsLogin a bounded window to produce its URL —
        # a never-registered node stays URL-less and falls through to the key.
        state=""; authUrl=""
        for _ in $(seq 1 15); do
          status="$(${pkgs.tailscale}/bin/tailscale status --json)"
          state="$(printf '%s' "$status" | ${pkgs.jq}/bin/jq -r '.BackendState')"
          authUrl="$(printf '%s' "$status" | ${pkgs.jq}/bin/jq -r '.AuthURL // ""')"
          case "$state" in
            Running|Stopped|NeedsMachineAuth) break ;;
            NeedsLogin) [ -n "$authUrl" ] && break ;;
          esac
          sleep 1
        done

        upFlags=( ${escapeShellArgs modeFlags} )
        usedAuthKey=""

        notify() {
          ${pkgs.curl}/bin/curl -fsS -m 10 -X POST \
            -H "Title: Tailscale auth needs an operator" \
            -H "Tags: warning" -H "Priority: high" \
            -d "$1" "${cfg.ntfyUrl}" || true
        }

        # Operator-actionable auth states exit 0: a failed wanted unit is
        # started (not restarted, so restartIfChanged cannot help) by every
        # switch, so exiting 1 here fails whole activations (exit 4 → the
        # rebuild trigger rolls back) until a human re-auths. The page below
        # and the journal carry the signal instead.
        if [ "$state" = "Running" ]; then
          echo "Already authenticated. Reapplying preferences..."
        elif [ -n "$authUrl" ]; then
          echo "Interactive re-auth already pending; not passing the stored authkey." >&2
          echo "Finish the login in a browser: $authUrl" >&2
          notify "${config.networking.hostName}: interactive tailscale re-auth pending: $authUrl"
          exit 0
        else
          echo "Authenticating with Tailscale..."
          upFlags+=( --authkey=file:${cfg.authKeyFile} )
          usedAuthKey=1
        fi

        if ! ${pkgs.tailscale}/bin/tailscale up "''${upFlags[@]}"; then
          if [ -n "$usedAuthKey" ]; then
            echo "tailscale up failed (BackendState=$state). The likeliest cause is" >&2
            echo "that the authkey in ${cfg.authKeyFile} has expired, or was" >&2
            echo "single-use and is already consumed. Mint a fresh key in the" >&2
            echo "Tailscale admin console, update secrets/homelab/tailscale.yaml," >&2
            echo "rebuild, then run:" >&2
            echo "  systemctl restart tailscale-autoconnect" >&2
            notify "${config.networking.hostName}: tailscale authkey rejected (BackendState=$state); node logged out until re-auth"
            exit 0
          else
            echo "tailscale up failed while reapplying preferences; no authkey was" >&2
            echo "involved. Inspect 'tailscale status' and 'journalctl -u tailscaled'." >&2
            exit 1
          fi
        fi
      '';
    };

    # IP forwarding is only needed when this node routes on behalf of others.
    boot.kernel.sysctl = mkIf isSubnetRouter {
      "net.ipv4.ip_forward" = mkDefault 1;
      "net.ipv6.conf.all.forwarding" = mkDefault 1;
    };

    # Quiets `tailscale up`'s UDP-GRO warning and raises forwarded-traffic
    # throughput. https://tailscale.com/s/ethtool-config-udp-gro
    # Always exits 0: a wanted oneshot that fails on a driver quirk would fail
    # whole activations, exactly like tailscale-autoconnect above.
    systemd.services.tailscale-gro-tune = mkIf isSubnetRouter {
      description = "Enable UDP GRO forwarding on the default-route interface";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        dev="$(${pkgs.iproute2}/bin/ip -o route get 8.8.8.8 2>/dev/null \
          | ${pkgs.gawk}/bin/awk '{for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1)}')"
        if [ -z "$dev" ]; then
          echo "no default-route interface found; skipping GRO tuning"
          exit 0
        fi
        if ${pkgs.ethtool}/bin/ethtool -K "$dev" rx-udp-gro-forwarding on rx-gro-list off; then
          echo "GRO forwarding tuned on $dev"
        else
          echo "ethtool could not change features on $dev (driver limitation); leaving defaults" >&2
        fi
      '';
    };

    networking.firewall = {
      trustedInterfaces = [ "tailscale0" ];

      # 41641 is tailscaled's default UDP port.
      allowedUDPPorts = [ config.services.tailscale.port ];
    };
  };
}
