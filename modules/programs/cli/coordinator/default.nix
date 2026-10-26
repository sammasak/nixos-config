# Coordinator agent (skills epic #16): a writable copy of the pinned skills input,
# fleet.json, the agent-scoped guard hook and the `coordinator` launcher.
# Imported applied:  (import .../coordinator inputs.skills)
skillsSrc:
{ config, lib, pkgs, osConfig, ... }:
let
  cfg = osConfig.sam.coordinator;
  home = config.home.homeDirectory;
  stateDir = "${config.xdg.stateHome}/coordinator";
  checkoutRoot = "${config.xdg.dataHome}/coordinator";
  rev = skillsSrc.shortRev or (builtins.substring 0 12 (baseNameOf skillsSrc));
  checkout = "${checkoutRoot}/skills-${rev}";
  permissions = builtins.fromJSON (builtins.readFile "${skillsSrc}/agents/coordinator/permissions.json");
  coordinatorSkills = lib.attrNames (lib.filterAttrs (n: t: t == "directory" && lib.hasPrefix "herdr-" n || n == "agent-handoff") (builtins.readDir "${skillsSrc}/skills"));
  guard = "${skillsSrc}/hooks/validate-coordinator.sh";
  userSettings = config.programs.claude-code.settings;
  # Only the role's permissions replace the user scope; host policy (telemetry env,
  # artifact switch, Herdr SessionStart hook) is carried over so the coordinator
  # stays a tracked Herdr agent under the same privacy settings.
  settings = {
    permissions = { inherit (permissions) allow ask deny; };
    env = userSettings.env or { };
    enableArtifact = userSettings.enableArtifact or false;
    hooks = {
      SessionStart = userSettings.hooks.SessionStart or [ ];
      PreToolUse = [{
        matcher = "Bash";
        hooks = [{ type = "command"; command = guard; timeout = 10; }];
      }];
    };
  };
  settingsFile = pkgs.writeText "coordinator-claude-settings.json" (builtins.toJSON settings);
  fleet = {
    schema_version = 1;
    hosts = map (h: { inherit (h) name ssh; }) cfg.fleet.hosts;
    repos = map (r: { inherit (r) name gh checkout; }) cfg.fleet.repos;
  };
  launcher = pkgs.writeShellApplication {
    name = "coordinator";
    runtimeInputs = [ pkgs.coreutils pkgs.claude-code pkgs.devenv pkgs.jq pkgs.openssh pkgs.git pkgs.gh pkgs.herdr ];
    # --setting-sources drops the user-scope allow list (bare Read/Bash on devTools hosts), so only
    # this file's rules and the guard apply to the coordinator's session.
    text = ''
      export COORDINATOR_CHECKOUT=${lib.escapeShellArg checkout}
      cd "$COORDINATOR_CHECKOUT"
      [ -x "$HOME/.claude/hooks/validate-coordinator.sh" ] || { echo "coordinator: guard hook missing; refusing to start" >&2; exit 2; }
      exec claude --agent coordinator --permission-mode default --setting-sources project,local --settings ${settingsFile} "$@"
    '';
  };
in
{
  home.packages = [ launcher ];

  home.file.".claude/hooks/validate-coordinator.sh".source = "${skillsSrc}/hooks/validate-coordinator.sh";
  xdg.configFile."coordinator/fleet.json".text = builtins.toJSON fleet;

  # devenv needs a writable project dir (.devenv/, eval cache), so the pinned
  # store copy is materialised once per skills revision; older copies stay for
  # rollback and the `current` link follows the active generation.
  home.activation.coordinatorCheckout = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run mkdir -p "${checkoutRoot}" "${stateDir}"
    run rm -rf "${checkoutRoot}"/skills-*.tmp
    if [ ! -f "${checkout}/.complete" ]; then
      run rm -rf "${checkout}" "${checkout}.tmp"
      run cp -r "${skillsSrc}" "${checkout}.tmp"
      run chmod -R u+w "${checkout}.tmp"
      # project-scoped agent and skills: --setting-sources project,local does not load user-scope ~/.claude/agents
      run mkdir -p "${checkout}.tmp/.claude/agents" "${checkout}.tmp/.claude/skills"
      run ln -sfn ../../agents/coordinator.md "${checkout}.tmp/.claude/agents/coordinator.md"
      for sk in ${lib.concatStringsSep " " (map lib.escapeShellArg coordinatorSkills)}; do run ln -sfn "../../skills/$sk" "${checkout}.tmp/.claude/skills/$sk"; done
      run touch "${checkout}.tmp/.complete"
      run mv "${checkout}.tmp" "${checkout}"
    fi
    run ln -sfn "${checkout}" "${checkoutRoot}/current"
    # keep the active copy plus the two newest others; each old copy pins a devenv closure via .devenv/gc
    find "${checkoutRoot}" -mindepth 1 -maxdepth 1 -type d -name 'skills-*' -not -path "${checkout}" -printf '%T@ %p\n' 2>/dev/null \
      | sort -rn | tail -n +3 | cut -d' ' -f2- | while read -r old; do run chmod -R u+w "$old" 2>/dev/null || true; run rm -rf "$old" || true; done
  '';
}
