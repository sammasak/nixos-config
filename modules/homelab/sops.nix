# The sops identity for the cluster secrets. ACME and Tailscale declare their
# own secrets, so a host that runs neither never decrypts those. Per-machine
# operator credentials are a different tree: sam.hostSecrets in modules/core/sops.nix.
{ config, lib, ... }:

let
  inherit (lib) mkEnableOption mkIf;
  cfg = config.homelab.secrets;
in
{
  options.homelab.secrets.enable = mkEnableOption "homelab secrets via sops-nix";

  config = mkIf cfg.enable {
    sops = {
      # The host SSH key, converted to age, is what makes decryption
      # unattended at activation time.
      age = {
        sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
        keyFile = "/var/lib/sops-nix/key.txt";
        generateKey = true;
      };
    };
  };
}
