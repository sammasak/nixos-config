# The host side of the agent runtime (#140): what the deploy-rs system profile
# carries. Templates arrive separately as the agent-runtime profile
# (template-profile.nix), so a template change is no host switch; nothing here
# references a manifest, and the system closure does not move with templates.
{ config, lib, pkgs, ... }:
let
  cfg = config.sam.agentRuntime;
  tools = import ./runtime.nix { inherit lib pkgs; };
in
{
  imports = [ ./default.nix ];

  config = lib.mkIf cfg.host.enable {
    environment.systemPackages = [ tools.instance ];
    environment.etc."agent-runtime/host.json".source = cfg.hostPolicy;
    # template-profile.nix checks schemaVersion; bump it with any change a template bundle must know about
    environment.etc."agent-runtime/substrate.json".text = builtins.toJSON {
      schemaVersion = 1;
      kind = "agent-runtime-substrate";
      manifestSchema = 1;
      instance = "${tools.instance}";
    };
    systemd.tmpfiles.rules = [
      "d /var/lib/agent-runtime 0700 root root -"
      # nix-env does not create a profile's parent: without it the first template deploy fails
      "d /nix/var/nix/profiles/agent-runtime 0755 root root -"
    ];
  };
}
