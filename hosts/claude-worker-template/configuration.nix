# Claude Worker agent image template (used for KubeVirt image builds).
{ ... }:
let
  vars = import ./variables.nix;
in
{
  imports = [
    ../../modules/homelab/workstation-image.nix
    ../../modules/homelab/claude-worker.nix
  ];

  # Credentials and CLAUDE.md are injected at runtime via KubeVirt cloud-init.

  sam.profile = vars;

  # Reuse the workstation image profile for VM-specific settings
  # (cloud-init, qemu guest agent, boot config, sleep/suspend disabled).
  homelab.workstation.enable = true;

  # Claude Worker agent runtime.
  homelab.claudeWorker.enable = true;

  # Enable containers subsystem (sets up /etc/containers/ for buildah/podman)
  virtualisation.containers.enable = true;

  # Grant lukas user namespace ranges required for rootless buildah
  users.users.${vars.username} = {
    subUidRanges = [{ startUid = 100000; count = 65536; }];
    subGidRanges = [{ startGid = 100000; count = 65536; }];
  };

  # Home Manager configuration for agent image template
  home-manager.users.${vars.username} = {
    home.stateVersion = "25.11";

    imports = [
      ../../modules/core/bash.nix
      ../../modules/core/starship.nix
      ../../modules/programs/cli/git
      ../../modules/programs/cli/cli-tools
      ../../modules/programs/cli/claude-code/default.nix
    ];
  };
}
