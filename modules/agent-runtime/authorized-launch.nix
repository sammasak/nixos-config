# #170: the one privileged entry point an authorized Coordinator may hold a NOPASSWD rule
# for -- a fixed wrapper taking only a runtime id and deriving its payload from the manifest.
# A `start`-level rule would instead be arbitrary root: start runs an unconstrained payload
# after `--`. Default off. See docs/agent-runtime-authorized-launch.md for the boundary.
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkOption types;
  cfg = config.sam.agentRuntime;
  tools = import ./runtime.nix { inherit lib pkgs; };
  wrapper = lib.getExe tools.authorizedStart;
in
{
  options.sam.agentRuntime.authorizedLaunch = {
    enable = mkEnableOption "the exact-command sudo wrapper that lets an authorized Coordinator start a created, admitted instance as root (#170)";
    user = mkOption {
      type = types.str;
      default = "";
      description = "The one user granted NOPASSWD sudo for the wrapper's exact store path; no other command is granted.";
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.authorizedLaunch.enable -> cfg.host.enable;
          message = "sam.agentRuntime.authorizedLaunch.enable requires host.enable (the lifecycle tool and host policy it drives).";
        }
        {
          assertion = cfg.authorizedLaunch.enable -> cfg.authorizedLaunch.user != "";
          message = "sam.agentRuntime.authorizedLaunch.user must name the authorized Coordinator when authorizedLaunch is enabled.";
        }
      ];
    }
    (lib.mkIf cfg.authorizedLaunch.enable {
      environment.systemPackages = [ tools.authorizedStart ];
      # Exactly one command, the wrapper's store path: no wildcard, no agent-runtime-instance.
      security.sudo.extraRules = [
        {
          users = [ cfg.authorizedLaunch.user ];
          commands = [
            {
              command = wrapper;
              options = [ "NOPASSWD" ];
            }
          ];
        }
      ];
    })
  ];
}
