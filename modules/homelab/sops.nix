# Cluster-scoped credentials, enabled only on nodes that join the cluster.
# Per-machine operator credentials are a different tree: sam.hostSecrets in
# modules/core/sops.nix.
{ config, lib, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption types;
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

    tailscaleSecretsFile = mkOption {
      type = types.path;
      default = ../../secrets/homelab/tailscale.yaml;
      description = "Path to the sops-encrypted Tailscale secrets file";
    };
  };

  config = mkIf cfg.enable {
    sops = {
      defaultSopsFile = cfg.sopsFile;

      # The host SSH key, converted to age, is what makes decryption
      # unattended at activation time.
      age = {
        sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
        keyFile = "/var/lib/sops-nix/key.txt";
        generateKey = true;
      };

      secrets."k3s/cluster_token" = {
        path = "/run/secrets/k3s-cluster-token";
        mode = "0400";
        restartUnits = [ "k3s.service" ];
      };

      secrets."flux/deploy_key" = {
        path = "/run/secrets/flux-deploy-key";
        mode = "0400";
        restartUnits = [ "flux-bootstrap.service" ];
      };

      secrets."flux/age_key" = {
        path = "/run/secrets/flux-age-key";
        mode = "0400";
        restartUnits = [ "flux-bootstrap.service" ];
      };

      secrets."cloudflare/api_token" = {
        sopsFile = cfg.cloudflareSecretsFile;
        path = "/run/secrets/cloudflare-api-token";
        mode = "0400";
      };

      secrets."tailscale/authkey" = {
        sopsFile = cfg.tailscaleSecretsFile;
        path = "/run/secrets/tailscale-authkey";
        owner = "root";
        mode = "0400";
      };
    };
  };
}
