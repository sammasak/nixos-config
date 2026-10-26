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
  # The adapter's `skills:` frontmatter list is the single source of truth for what gets project-scoped.
  adapterLines = lib.splitString "\n" (builtins.readFile "${skillsSrc}/agents/coordinator.md");
  afterSkills = lib.drop (lib.lists.findFirstIndex (l: l == "skills:") (-1) adapterLines + 1) adapterLines;
  listItems = xs: if xs == [ ] || !lib.hasPrefix "  - " (builtins.head xs) then [ ] else [ (lib.removePrefix "  - " (builtins.head xs)) ] ++ listItems (builtins.tail xs);
  coordinatorSkills = listItems afterSkills;
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
  # bump when the materialised layout changes so existing copies get rebuilt
  layoutVersion = "3-" + lib.concatStringsSep "," coordinatorSkills;
  launcher = pkgs.writeShellApplication {
    name = "coordinator";
    runtimeInputs = [ pkgs.coreutils pkgs.claude-code pkgs.devenv pkgs.jq pkgs.openssh pkgs.git pkgs.gh pkgs.herdr ];
    # --setting-sources drops user-scope settings (bare Read/Bash allow on devTools hosts); project scope
    # is the pinned checkout, and the rendered file carries the role's rules plus the host's env/hooks.
    text = ''
      export COORDINATOR_CHECKOUT=${lib.escapeShellArg checkout}
      [ -f "$COORDINATOR_CHECKOUT/.complete" ] || { echo "coordinator: checkout not materialised; re-run the Home Manager activation" >&2; exit 2; }
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
    wipe() { for d in "$@"; do [ -e "$d" ] || continue; run chmod -R u+w "$d" 2>/dev/null || true; run rm -rf "$d" || true; done; }
    run mkdir -p "${checkoutRoot}" "${stateDir}"
    wipe "${checkoutRoot}"/skills-*.tmp
    if [ "$(cat "${checkout}/.complete" 2>/dev/null)" != "${layoutVersion}" ]; then
      wipe "${checkout}" "${checkout}.tmp"
      run cp -r "${skillsSrc}" "${checkout}.tmp"
      run chmod -R u+w "${checkout}.tmp"
      # project-scoped agent and skills: --setting-sources project,local does not load user-scope ~/.claude/agents
      run mkdir -p "${checkout}.tmp/.claude/agents" "${checkout}.tmp/.claude/skills"
      run ln -sfn ../../agents/coordinator.md "${checkout}.tmp/.claude/agents/coordinator.md"
      for sk in ${lib.concatStringsSep " " (map lib.escapeShellArg coordinatorSkills)}; do run ln -sfn "../../skills/$sk" "${checkout}.tmp/.claude/skills/$sk"; done
      # .integrity lets the guard refuse every task call once a contract, task, hook or devenv file in the copy changes
      run sh -c ${lib.escapeShellArg "cd '${checkout}.tmp' && find agents task-modules hooks devenv.nix devenv.yaml devenv.lock -type f -print0 | sort -z | xargs -0 sha256sum > .integrity"}
      run sh -c ${lib.escapeShellArg "printf '%s' '${layoutVersion}' > '${checkout}.tmp/.complete'"}
      run mv "${checkout}.tmp" "${checkout}"
    fi
    run ln -sfn "${checkout}" "${checkoutRoot}/current"
    # keep the active copy plus the two newest others; each old copy pins a devenv closure via .devenv/gc
    { find "${checkoutRoot}" -mindepth 1 -maxdepth 1 -type d -name 'skills-*' -not -path "${checkout}" -printf '%T@ %p\n' 2>/dev/null \
      | sort -rn | tail -n +3 | cut -d' ' -f2- | while read -r old; do wipe "$old"; done; } || true
  '';
}
