# The session user's tools: `agent-runtime-session` (attach needs no root) and, default off, the
# one NOPASSWD rule that lets that user start and end a session through a fixed helper taking a
# verb, an id, a template name and a task ref. A rule on `agent-runtime-instance start` would be
# arbitrary root (start runs any payload after `--`). See docs/agent-runtime-session.md.
{ config, lib, pkgs, ... }:
let
  cfg = config.sam.agentRuntime;
  tools = import ./runtime.nix { inherit lib pkgs; };
  paneNames = lib.filter (n: n != null) (lib.mapAttrsToList (_: t: t.session.paneProcessName) cfg.templates);
in
{
  options.sam.agentRuntime.session.launch.enable = lib.mkEnableOption "the exact-command sudo rule that lets `session.attachUser` start and end interactive sessions as root through `agent-runtime-session-launch`";

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.session.launch.enable -> cfg.host.enable && cfg.session.attachUser != null;
          message = "sam.agentRuntime.session.launch.enable requires host.enable and session.attachUser (the one user the rule names).";
        }
      ];
    }
    (lib.mkIf cfg.host.enable {
      environment.systemPackages = [ (tools.session paneNames) ];
      # the shipped hook: a Herdr notification per event; a host's own list replaces it
      sam.agentRuntime.session.hooks = lib.genAttrs [ "start" "end" ] (_: lib.mkDefault [ (lib.getExe tools.sessionNotify) ]);
    })
    (lib.mkIf cfg.session.launch.enable {
      # Exactly one command as root only: no wildcard, no agent-runtime-instance.
      security.sudo.extraRules = [
        {
          users = [ cfg.session.attachUser ];
          runAs = "root";
          commands = [
            {
              command = lib.getExe tools.sessionLaunch;
              options = [ "NOPASSWD" ];
            }
          ];
        }
      ];
    })
  ];
}
