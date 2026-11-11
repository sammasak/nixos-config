# The host side of the agent runtime (#140): what the deploy-rs system profile
# carries. Templates arrive separately as the agent-runtime profile
# (template-profile.nix), so a template change is no host switch; nothing here
# references a manifest, and the system closure does not move with templates.
# The one template fact read here is whether an eligible template has egress.
{ config, lib, pkgs, ... }:
let
  cfg = config.sam.agentRuntime;
  tools = import ./runtime.nix { inherit lib pkgs; };
  egress = lib.any (n: (cfg.templates.${n}.network.allow or null) != null) cfg.host.eligibleTemplates;
in
{
  imports = [ ./default.nix ./authorized-launch.nix ];

  config = lib.mkMerge [
    # the promote/verify client alone, for a coordinator that must not admit instances (docs/agent-runtime-coder.md)
    (lib.mkIf cfg.clientTools.enable {
      environment.systemPackages = [ tools.verify tools.promote ];
      environment.etc = lib.mapAttrs' (h: dir: lib.nameValuePair "agent-runtime/client-templates/${h}" { source = dir; }) cfg.clientTools.templateManifests;
    })
    (lib.mkIf cfg.host.enable {
      # the lifecycle, the Herdr adapter (#139), the pilot's preflight and pane (#165), the bundle verifier (#169)
      environment.systemPackages = [ tools.instance tools.preflight tools.pane tools.verify (import ./herdr { inherit pkgs; }) ];
      environment.etc."agent-runtime/host.json".source = cfg.hostPolicy;
      # template-profile.nix checks schemaVersion; bump it with any change a template bundle must know about
      environment.etc."agent-runtime/substrate.json".text = builtins.toJSON {
        schemaVersion = 1;
        kind = "agent-runtime-substrate";
        manifestSchema = 1;
        instance = "${tools.instance}";
      };
      # allowlist egress is forwarded and masqueraded off the host; without it `start` refuses.
      # mkDefault: k3s and tailscale declare the same key and equal definitions do not merge.
      boot.kernel.sysctl."net.ipv4.ip_forward" = lib.mkIf egress (lib.mkDefault 1);
      assertions = [
        {
          assertion = !egress || lib.elem config.boot.kernel.sysctl."net.ipv4.ip_forward" [ 1 "1" true ];
          message = "sam.agentRuntime.host: an eligible template declares an egress allowlist, which needs boot.kernel.sysctl.\"net.ipv4.ip_forward\" = 1";
        }
      ];
      # Not agent-runtime-<name>.service: that namespace is the instances' own transient units.
      systemd.services.agent-runtime = {
        description = "agent-runtime: settle runs the last shutdown interrupted, publish the host status";
        wantedBy = [ "multi-user.target" ];
        # time-sync: settle compares a run's start with the boot time; with a wrong clock it settles nothing
        after = [ "local-fs.target" "time-sync.target" "systemd-sysctl.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = lib.getExe tools.boot;
        };
      };
      systemd.tmpfiles.rules = [
        "d /var/lib/agent-runtime 0700 root root -"
        # nix-env does not create a profile's parent: without it the first template deploy fails
        "d /nix/var/nix/profiles/agent-runtime 0755 root root -"
      ];
    })
  ];
}
