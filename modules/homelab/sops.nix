# The sops identity and the k3s token for nodes that join the cluster. Flux,
# ACME and Tailscale declare their own secrets, so a node that runs none of
# them never decrypts those. Per-machine operator credentials are a different tree: sam.hostSecrets in
# modules/core/sops.nix.
{ config, lib, ... }:

let
  inherit (lib) mkEnableOption mkIf;
  cfg = config.homelab.secrets;
in
{
  options.homelab.secrets.enable = mkEnableOption "homelab secrets via sops-nix";

  config = mkIf cfg.enable {
    sops = {
      defaultSopsFile = ../../secrets/homelab/k3s.yaml;

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
    };
  };
}
