# Takes the skills flake input as its first argument, so it is
# imported applied:  import .../skills.nix inputs.skills
skillsSrc:
{ lib, ... }:
let
  skillEntries = builtins.readDir "${skillsSrc}/skills";
  skillDirs = lib.filterAttrs (_: type: type == "directory") skillEntries;

  agentEntries = builtins.readDir "${skillsSrc}/agents";
  agentFiles = lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".md" name) agentEntries;
  # a role adapter (an .md with a sibling agents/<name>/ contract) is only safe to link when the same skills
  # revision ships the settings-level dispatcher that guards it; an older pin must fail evaluation, not link it bare
  roleContracts = lib.filterAttrs (name: type: type == "directory" && builtins.pathExists "${skillsSrc}/agents/${name}/ROLE.md") agentEntries;
  guarded = roleContracts == { } || builtins.pathExists "${skillsSrc}/hooks/role-guard-dispatch.sh";
in
{
  assertions = [{
    assertion = guarded;
    message = "skills input ships role contracts (${lib.concatStringsSep ", " (builtins.attrNames roleContracts)}) but no hooks/role-guard-dispatch.sh; bump the skills input before linking role adapters.";
  }];
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
