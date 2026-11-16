# Per-machine operator credentials, on the hosts that enable them (not naked-pi),
# whatever their homelab role. Homelab secrets (Cloudflare, Tailscale) are a different tree:
# homelab.secrets in modules/homelab/sops.nix.
{ config, lib, ... }:

let
  cfg = config.sam.hostSecrets;
  username = config.sam.profile.username;
  dev = config.services.devEnvironments;
  custom = lib.attrNames (
    lib.filterAttrs (
      name: s: lib.hasPrefix "/run/secrets/" s.path && s.path != "/run/secrets/${name}"
    ) config.sops.secrets
  );
in
{
  options.sam.hostSecrets = {
    enable = lib.mkEnableOption "per-machine operator credentials via sops-nix";
  };

  config = lib.mkMerge [
    {
      # sops-nix repoints the symlink dir to the new generation before it recreates a custom path's symlink inside it,
      # so such a path is absent for a moment at every switch; a default path is in the generation before the switch
      assertions = [
        {
          assertion = custom == [ ];
          message = "sops secrets ${toString custom} set a custom path inside /run/secrets; drop it and read config.sops.secrets.<name>.path.";
        }
      ];
    }
    (lib.mkIf cfg.enable {
      sops = {
        age = {
          sshKeyPaths = lib.mkDefault [ "/etc/ssh/ssh_host_ed25519_key" ];
          keyFile = lib.mkDefault "/var/lib/sops-nix/key.txt";
          generateKey = lib.mkDefault true;
        };

        secrets = {
          # Read by the devTools fish init and coordinator wake-up, and by the workers' egress proxy, whose own
          # restartUnits declaration (modules/workers) would otherwise leave this secret without its sopsFile.
          "claude_oauth_token" =
            lib.mkIf
              (config.sam.profile.devTools || lib.any dev.egress.anthropic.for (lib.attrValues dev.instances))
              {
                sopsFile = ../../secrets/claude/oauth.yaml;
                owner = username;
                mode = "0400";
              };

          # Pi's project key for acer's llm-gateway (modules/homelab/llm-gateway.nix). Read by Pi's
          # `homelab` provider at request time (modules/programs/cli/pi); no provider keys, so every
          # pi host may hold it.
          "llm_gateway_pi_key" = lib.mkIf config.sam.profile.pi {
            sopsFile = ../../secrets/claude/llm-gateway.yaml;
            owner = username;
            mode = "0400";
          };

          # Decrypted to /run/secrets/nix_access_token, which nix.conf includes at
          # runtime so nix can fetch private flake inputs. It lives under
          # secrets/homelab/ for the `homelab/*.yaml` recipient rule in
          # secrets/.sops.yaml, not because it is a homelab service secret — moving it
          # breaks decryption until the rule moves with it.
          "nix_access_token" = {
            sopsFile = ../../secrets/homelab/github-access-token.yaml;
            owner = "root";
            mode = "0400";
          };
        };
      };

      # Soft-include so nix doesn't fail before sops activates on first boot.
      nix.extraOptions = ''
        !include ${config.sops.secrets."nix_access_token".path}
      '';
    })
  ];
}
