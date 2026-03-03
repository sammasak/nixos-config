# OpenFang agent image template (used for KubeVirt image builds).
{ lib, pkgs, config, ... }:
let
  vars = import ./variables.nix;
in
{
  imports = [
    ../../modules/homelab/workstation-image.nix
    ../../modules/homelab/openfang.nix
  ];

  # Secrets: OpenFang config.toml and API credentials are injected at runtime
  # via KubeVirt cloud-init from Kubernetes Secrets. No SOPS needed at
  # image build time (unlike workstation-template which uses sops-nix).

  sam.profile = vars;

  # Reuse the workstation image profile for VM-specific settings
  # (cloud-init, qemu guest agent, boot config, sleep/suspend disabled).
  homelab.workstation.enable = true;

  # OpenFang agent runtime with all MCP servers enabled.
  homelab.openfang = {
    enable = true;
    configFile = "/var/lib/openfang/config.toml";
    mcpServers = {
      kubernetes.enable = true;
      grafana.enable = true;
      flux.enable = true;
    };
  };

  # Enable containers subsystem (sets up /etc/containers/ for buildah/podman)
  virtualisation.containers.enable = true;

  # Grant lukas user namespace ranges required for rootless buildah
  users.users.${vars.username} = {
    subUidRanges = [{ startUid = 100000; count = 65536; }];
    subGidRanges = [{ startGid = 100000; count = 65536; }];
  };

  # Increase disk image size beyond the default 512M additional space.
  # The nixos kubevirt format auto-sizes to closure + additionalSpace; the
  # default 512M leaves agents with no room for cargo/nix builds at runtime.
  # 30GiB of headroom: enough for nix store (~8GB baked) + cargo (~5GB) +
  # nix develop installs (~5GB) with comfortable margin.
  system.build.kubevirtImage = lib.mkForce (import "${toString pkgs.path}/nixos/lib/make-disk-image.nix" {
    inherit lib config pkgs;
    inherit (config.image) baseName;
    format = "qcow2";
    additionalSpace = "22000M";  # ~22GB extra on top of baked nix store → ~30GB total
  });

  # Home Manager configuration for agent image template
  home-manager.users.${vars.username} = {
    home.stateVersion = "25.11";

    imports = [
      ../../modules/core/bash.nix
      ../../modules/core/starship.nix
      ../../modules/programs/cli/git
      ../../modules/programs/cli/cli-tools
    ];
  };
}
