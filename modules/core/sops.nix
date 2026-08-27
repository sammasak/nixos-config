# Per-machine operator credentials, on every physical host regardless of cluster
# role. Cluster secrets (k3s, Flux, Cloudflare, Tailscale) are a different tree:
# homelab.secrets in modules/homelab/sops.nix.
{ config, lib, ... }:

let
  cfg = config.sam.hostSecrets;
  username = config.sam.profile.username;
in
{
  options.sam.hostSecrets = {
    enable = lib.mkEnableOption "per-machine operator credentials via sops-nix";
  };

  config = lib.mkIf cfg.enable {
    sops = {
      age = {
        sshKeyPaths = lib.mkDefault [ "/etc/ssh/ssh_host_ed25519_key" ];
        keyFile = lib.mkDefault "/var/lib/sops-nix/key.txt";
        generateKey = lib.mkDefault true;
      };

      secrets = {
        "claude_oauth_token" = {
          sopsFile = ../../secrets/claude/oauth.yaml;
          owner = username;
          mode = "0400";
        };

        # Decrypted to /run/secrets/nix_access_token, which nix.conf includes at
        # runtime so nix can fetch private flake inputs. It lives under
        # secrets/homelab/ for the `homelab/*.yaml` recipient rule in
        # secrets/.sops.yaml, not because it is a cluster secret — moving it
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
  };
}
