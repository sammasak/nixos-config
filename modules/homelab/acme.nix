# ACME certificate management for homelab
# Uses Cloudflare DNS-01 validation for Let's Encrypt certificates
{ config, lib, ... }:

let
  cfg = config.homelab.acme;
  inherit (lib) mkEnableOption mkOption mkIf types;
in
{
  options.homelab.acme = {
    enable = mkEnableOption "ACME certificate management";

    email = mkOption {
      type = types.str;
      default = "admin@sammasak.dev";
      description = "Email for Let's Encrypt registration";
    };

    dnsDomain = mkOption {
      type = types.str;
      default = "dns.sammasak.dev";
      description = "DNS service domain for DoT/DoH certificates";
    };
  };

  config = mkIf cfg.enable {
    security.acme = {
      acceptTerms = true;
      defaults.email = cfg.email;

      certs."${cfg.dnsDomain}" = {
        # DNS-01 validation via Cloudflare (no public exposure needed)
        dnsProvider = "cloudflare";

        # Cloudflare API token read from sops-managed file
        credentialFiles = {
          "CLOUDFLARE_DNS_API_TOKEN_FILE" = "/run/secrets/cloudflare-api-token";
        };

        # Reload AdGuard Home when certificate is renewed
        reloadServices = [ "adguardhome.service" ];

        # Group that can read the certificates
        group = "acme";
      };
    };

    # Ensure ACME services wait for secrets (Cloudflare token)
    systemd.services."acme-order-renew-${cfg.dnsDomain}" = {
      after = [ "sops-nix.service" ];
      wants = [ "sops-nix.service" ];
    };
  };
}
