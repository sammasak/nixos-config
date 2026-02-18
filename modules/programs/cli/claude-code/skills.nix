# Symlink personal Claude Code skills and agents from the claude-code-skills repo.
#
# Usage (in 40-outputs-nixos.nix):
#   import ../modules/programs/cli/claude-code/skills.nix inputs.claude-code-skills
#
# This produces a Home Manager module that creates ~/.claude/skills/* and
# ~/.claude/agents/* symlinks pointing into the Nix store.
skillsSrc:
{ lib, ... }:
let
  # Discover skill directories (each subdir of skills/ with a SKILL.md)
  skillEntries = builtins.readDir "${skillsSrc}/skills";
  skillDirs = lib.filterAttrs (_: type: type == "directory") skillEntries;

  # Discover agent files (*.md files in agents/)
  agentEntries = builtins.readDir "${skillsSrc}/agents";
  agentFiles = lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".md" name) agentEntries;
in
{
  home.file =
    # ~/.claude/skills/<name>/ → nix store
    (lib.mapAttrs' (name: _:
      lib.nameValuePair ".claude/skills/${name}" {
        source = "${skillsSrc}/skills/${name}";
        recursive = true;
      }
    ) skillDirs)
    //
    # ~/.claude/agents/<name>.md → nix store
    (lib.mapAttrs' (name: _:
      lib.nameValuePair ".claude/agents/${name}" {
        source = "${skillsSrc}/agents/${name}";
      }
    ) agentFiles);
}
