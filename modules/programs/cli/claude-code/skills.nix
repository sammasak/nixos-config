# Takes the skills flake input as its first argument, so it is
# imported applied:  import .../skills.nix inputs.skills
skillsSrc:
{ lib, osConfig, ... }:
let
  skillEntries = builtins.readDir "${skillsSrc}/skills";
  skillDirs = lib.filterAttrs (_: type: type == "directory") skillEntries;

  # The coordinator drives the workers this host saves in Herdr; on a worker it
  # would only see itself, so its adapter stays off there (docs/rollout-coordinator.md).
  coordinatorHost = (osConfig.sam.herdr.machines or [ ]) != [ ];
  agentEntries = builtins.readDir "${skillsSrc}/agents";
  agentFiles = lib.filterAttrs (name: type:
    type == "regular" && lib.hasSuffix ".md" name && (coordinatorHost || name != "coordinator.md")
  ) agentEntries;
in
{
  home.file =
    { ".claude/CLAUDE.md".source = "${skillsSrc}/global-context.md"; }
    //
    (lib.mapAttrs' (name: _:
      lib.nameValuePair ".claude/skills/${name}" {
        source = "${skillsSrc}/skills/${name}";
        recursive = true;
      }
    ) skillDirs)
    //
    (lib.mapAttrs' (name: _:
      lib.nameValuePair ".claude/agents/${name}" {
        source = "${skillsSrc}/agents/${name}";
      }
    ) agentFiles);
}
