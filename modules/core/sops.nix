# SOPS secrets shared across all physical hosts (Claude Code OAuth token, etc.)
{ config, lib, ... }:

let
  cfg = config.sam.secrets;
  username = config.sam.profile.username;
in
{
  options.sam.secrets = {
    enable = lib.mkEnableOption "shared secrets via sops-nix";
  };

  config = lib.mkIf cfg.enable {
    sops = {
      age = {
        sshKeyPaths = lib.mkDefault [ "/etc/ssh/ssh_host_ed25519_key" ];
        keyFile = lib.mkDefault "/var/lib/sops-nix/key.txt";
        generateKey = lib.mkDefault true;
      };

      secrets."claude_oauth_token" = {
        sopsFile = ../../secrets/claude/oauth.yaml;
        owner = username;
        mode = "0400";
      };

      # GitHub access token for nix to fetch private flake inputs.
      # Decrypted to /run/secrets/nix-access-token, included by nix.conf at runtime.
      secrets."nix_access_token" = {
        sopsFile = ../../secrets/homelab/github-access-token.yaml;
        owner = "root";
        mode = "0400";
      };
    };

    # Soft-include so nix doesn't fail before sops activates on first boot.
    nix.extraOptions = ''
      !include /run/secrets/nix_access_token
    '';
  };
}
