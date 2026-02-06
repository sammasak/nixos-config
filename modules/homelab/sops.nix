# SOPS secrets configuration for homelab
{ config, lib, ... }:

with lib;

let
  cfg = config.homelab.secrets;
in
{
  options.homelab.secrets = {
    enable = mkEnableOption "homelab secrets via sops-nix";

    sopsFile = mkOption {
      type = types.path;
      default = ../../secrets/homelab/k3s.yaml;
      description = "Path to the sops-encrypted secrets file";
    };

    cloudflareSecretsFile = mkOption {
      type = types.path;
      default = ../../secrets/homelab/cloudflare.yaml;
      description = "Path to the sops-encrypted Cloudflare secrets file";
    };
  };

  config = mkIf cfg.enable {
    # Configure sops-nix
    sops = {
      defaultSopsFile = cfg.sopsFile;

      # Use the host's SSH key for decryption (converted to age)
      # This allows unattended decryption during system activation
      age = {
        # sops-nix will automatically use keys from:
        # - ~/.config/sops/age/keys.txt (user key)
        # - /etc/ssh/ssh_host_ed25519_key (host key, if ssh-to-age configured)
        sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
        keyFile = "/var/lib/sops-nix/key.txt";
        generateKey = true;
      };

      # Define the k3s cluster token secret
      secrets."k3s/cluster_token" = {
        # The secret will be available at this path
        path = "/run/secrets/k3s-cluster-token";
        # Restart k3s when the secret changes
        restartUnits = [ "k3s.service" ];
      };

      # Flux GitOps secrets
      secrets."flux/deploy_key" = {
        path = "/run/secrets/flux-deploy-key";
        # Restart flux-bootstrap when the secret changes
        restartUnits = [ "flux-bootstrap.service" ];
      };

      secrets."flux/age_key" = {
        path = "/run/secrets/flux-age-key";
        restartUnits = [ "flux-bootstrap.service" ];
      };

      # Cloudflare API token for ACME DNS-01 validation
      secrets."cloudflare/api_token" = {
        sopsFile = cfg.cloudflareSecretsFile;
        path = "/run/secrets/cloudflare-api-token";
      };
    };
  };
}
