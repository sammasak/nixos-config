# Takes the skills flake input as its first argument, so it is
# imported applied:  import .../skills.nix inputs.skills
skillsSrc:
{ lib, ... }:
let
  skillEntries = builtins.readDir "${skillsSrc}/skills";
  skillDirs = lib.filterAttrs (_: type: type == "directory") skillEntries;

  agentEntries = builtins.readDir "${skillsSrc}/agents";
  # role adapters (<name>.md next to an agents/<name>/ contract) are not user-scope agents: a role launcher
  # project-scopes its own adapter and guard, and linked here they would only attract delegation that the
  # missing guard then refuses
  agentFiles = lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".md" name && !(agentEntries.${lib.removeSuffix ".md" name} or null == "directory")) agentEntries;
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
