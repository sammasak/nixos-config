# Let's Encrypt through Cloudflare DNS-01: the defaults every certificate inherits. Each use site declares its own
# certificate, group and reloads (adguardhome.nix, edge.nix).
{ config, lib, ... }:

let
  cfg = config.homelab.acme;
in
{
  imports = [ ./sops.nix ];

  options.homelab.acme.enable = lib.mkEnableOption "ACME certificate management";

  config = lib.mkIf cfg.enable {
    homelab.secrets.enable = true;

    sops.secrets."cloudflare/api_token" = {
      sopsFile = ../../secrets/homelab/cloudflare.yaml;
      path = "/run/secrets/cloudflare-api-token";
      mode = "0400";
    };

    security.acme = {
      acceptTerms = true;
      defaults = {
        email = "admin@sammasak.dev";
        dnsProvider = "cloudflare";

        # Use public DNS resolvers for SOA lookups so that cert renewal is not
        # coupled to local DNS infrastructure (AdGuard Home via Tailscale split
        # DNS). Without this, lego reads /etc/resolv.conf, gets Tailscale
        # MagicDNS (100.100.100.100), which routes sammasak.dev queries to
        # AdGuard Home (192.168.10.154). If AdGuard Home is down, lego cannot
        # find the zone and Cloudflare API fails.
        dnsResolver = "1.1.1.1:53";
        extraLegoFlags = [
          "--dns.resolvers"
          "8.8.8.8:53"
        ];

        credentialFiles = {
          "CLOUDFLARE_DNS_API_TOKEN_FILE" = config.sops.secrets."cloudflare/api_token".path;
        };
      };
    };

    systemd.services = lib.mapAttrs' (
      name: _:
      lib.nameValuePair "acme-order-renew-${name}" {
        after = [ "sops-nix.service" ];
        wants = [ "sops-nix.service" ];
      }
    ) config.security.acme.certs;
  };
}
