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
  guard = "${skillsSrc}/hooks/validate-coordinator.sh";
  # Rules use ~/ paths, which Claude Code resolves itself; nothing to rewrite.
  settings = {
    permissions = { inherit (permissions) allow ask deny; };
    # Same guard as the agent frontmatter, from the immutable store path so it cannot go missing mid-session.
    hooks.PreToolUse = [{
      matcher = "Bash";
      hooks = [{ type = "command"; command = guard; timeout = 10; }];
    }];
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
    if [ ! -d "${checkout}" ]; then
      run cp -r "${skillsSrc}" "${checkout}.tmp"
      run chmod -R u+w "${checkout}.tmp"
      run mv "${checkout}.tmp" "${checkout}"
    fi
    run ln -sfn "${checkout}" "${checkoutRoot}/current"
    # keep the active copy plus the two newest others; each old copy pins a devenv closure via .devenv/gc
    for old in $(ls -1dt "${checkoutRoot}"/skills-*/ 2>/dev/null | grep -vF "${checkout}/" | tail -n +3); do run rm -rf "$old"; done
  '';
}
