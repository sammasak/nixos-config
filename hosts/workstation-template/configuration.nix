# Workstation image template (used for KubeVirt image builds).
{ ... }:
let
  vars = import ./variables.nix;
in
{
  imports = [
    ../../modules/homelab/workstation-image.nix
  ];

  sam.profile = vars;

  homelab.workstation.enable = true;

  # Embed static age identity so sops-nix can decrypt shared secrets at boot.
  # All VM instances share this key (accepted tradeoff for shared golden image).
  environment.etc."age/workstation-identity.key" = {
    source = ./age-identity.key;
    mode = "0400";
  };

  sops = {
    age = {
      sshKeyPaths = [];  # VMs have ephemeral SSH host keys; use embedded age key instead
      keyFile = "/etc/age/workstation-identity.key";
      generateKey = false;
    };
    secrets."claude_oauth_token" = {
      sopsFile = ../../secrets/claude/oauth.yaml;
      owner = vars.username;
      mode = "0400";
    };
  };
}
