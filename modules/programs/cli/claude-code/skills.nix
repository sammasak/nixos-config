# Takes the claude-code-skills flake input as its first argument, so it is
# imported applied:  import .../skills.nix inputs.claude-code-skills
skillsSrc:
{ lib, ... }:
let
  skillEntries = builtins.readDir "${skillsSrc}/skills";
  skillDirs = lib.filterAttrs (_: type: type == "directory") skillEntries;

  agentEntries = builtins.readDir "${skillsSrc}/agents";
  agentFiles = lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".md" name) agentEntries;
in
{
  home.file =
    { ".claude/CLAUDE.md".source = "${skillsSrc}/CLAUDE.md"; }
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
