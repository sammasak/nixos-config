# OpenFang agent image template (used for KubeVirt image builds).
{ ... }:
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
