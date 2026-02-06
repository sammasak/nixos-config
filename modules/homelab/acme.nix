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

    domain = mkOption {
      type = types.str;
      default = "sammasak.dev";
      description = "Base domain for certificates";
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
      # Placeholder email - actual email loaded via LEGO_EMAIL env var at runtime
      # from sops-encrypted /run/secrets/acme-env
      defaults.email = "placeholder@example.com";

      certs."${cfg.dnsDomain}" = {
        # DNS-01 validation via Cloudflare (no public exposure needed)
        dnsProvider = "cloudflare";

        # Cloudflare API token read from sops-managed file
        credentialFiles = {
          "CLOUDFLARE_DNS_API_TOKEN_FILE" = "/run/secrets/cloudflare-api-token";
        };

        # Also request wildcard for future HTTPS services
        extraDomainNames = [ "*.${cfg.domain}" ];

        # Reload AdGuard Home when certificate is renewed
        reloadServices = [ "adguardhome.service" ];

        # Group that can read the certificates
        group = "acme";
      };
    };

    # Override ACME services to load email from sops-encrypted environment file
    # The order-renew service is the one that actually runs lego
    systemd.services."acme-order-renew-${cfg.dnsDomain}" = {
      after = [ "sops-nix.service" ];
      wants = [ "sops-nix.service" ];
      serviceConfig.EnvironmentFile = "/run/secrets/acme-env";
    };

    systemd.services."acme-${cfg.dnsDomain}" = {
      after = [ "sops-nix.service" ];
      wants = [ "sops-nix.service" ];
    };
  };
}
