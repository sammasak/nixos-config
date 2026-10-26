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
  # Adding a skill to the adapter's `skills:` frontmatter is enough to project-scope it here.
  adapterLines = lib.splitString "\n" (builtins.readFile "${skillsSrc}/agents/coordinator.md");
  skillsIdx = lib.lists.findFirstIndex (l: l == "skills:") null adapterLines;
  listItems = xs: if xs == [ ] || !lib.hasPrefix "  - " (builtins.head xs) then [ ] else [ (lib.removePrefix "  - " (builtins.head xs)) ] ++ listItems (builtins.tail xs);
  coordinatorSkills =
    if skillsIdx == null then throw "coordinator: agents/coordinator.md has no skills: block"
    else let xs = listItems (lib.drop (skillsIdx + 1) adapterLines); in if xs == [ ] then throw "coordinator: skills: block is empty or not a block list" else xs;
  # roots the manifest covers; the skills repo ships the list so guard, tests and this module agree
  integrityPathsFile = "${skillsSrc}/hooks/lib/integrity-paths";
  # the guard's own predicate decides whether a copy is intact, so activation rebuilds exactly what the guard refuses
  integrityCheck =
    if builtins.pathExists "${skillsSrc}/hooks/lib/integrity-check.sh" then "${skillsSrc}/hooks/lib/integrity-check.sh"
    else throw "coordinator: the skills input has no hooks/lib/integrity-check.sh; bump the skills input to a revision from epic #16 M4";
  integrityRoots =
    if builtins.pathExists integrityPathsFile
    then lib.filter (l: l != "" && !lib.hasPrefix "#" l) (map (l: lib.removeSuffix "\r" l) (lib.splitString "\n" (builtins.readFile integrityPathsFile)))
    else throw "coordinator: the skills input has no hooks/lib/integrity-paths; bump the skills input to a revision from epic #16 M4";
  rootsArg = lib.concatStringsSep " " (map lib.escapeShellArg integrityRoots);
  pinFile = "${config.xdg.configHome}/coordinator/skills-${rev}.integrity.sha256";
  guard = "${skillsSrc}/hooks/validate-coordinator.sh";
  userSettings = config.programs.claude-code.settings;
  # Only the role's permissions replace the user scope; host policy (telemetry env,
  # artifact switch, Herdr SessionStart hook) is carried over so the coordinator
  # stays a tracked Herdr agent under the same privacy settings.
  settings = {
    permissions = { inherit (permissions) allow ask deny; };
    # quality:gate may run up to 540 s; Claude's Bash tool defaults to 120 s
    env = (userSettings.env or { }) // { BASH_DEFAULT_TIMEOUT_MS = "600000"; BASH_MAX_TIMEOUT_MS = "600000"; };
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
  layoutVersion = "5-" + lib.concatStringsSep "," coordinatorSkills;
  launcher = pkgs.writeShellApplication {
    name = "coordinator";
    runtimeInputs = [ pkgs.coreutils pkgs.claude-code pkgs.devenv pkgs.jq pkgs.openssh pkgs.git pkgs.gh pkgs.herdr ];
    # --setting-sources drops user-scope settings (bare Read/Bash allow on devTools hosts); project scope
    # is the pinned checkout, and the rendered file carries the role's rules plus the host's env/hooks.
    text = ''
      export COORDINATOR_CHECKOUT=${lib.escapeShellArg checkout}
      [ -f "$COORDINATOR_CHECKOUT/.complete" ] || { echo "coordinator: checkout not materialised; re-run the Home Manager activation" >&2; exit 2; }
      # the guard must find the manifest and its pinned hash (kept outside the checkout) on every call
      export COORDINATOR_REQUIRE_INTEGRITY=1
      COORDINATOR_INTEGRITY_SHA256=$(cat ${lib.escapeShellArg pinFile}) || { echo "coordinator: integrity pin missing; re-run the activation" >&2; exit 2; }
      export COORDINATOR_INTEGRITY_SHA256
      cd "$COORDINATOR_CHECKOUT"
      # the agent frontmatter runs the guard from this path (the settings file runs the store copy); both must exist
      [ -x "$HOME/.claude/hooks/validate-coordinator.sh" ] || { echo "coordinator: guard hook missing; refusing to start" >&2; exit 2; }
      ${lib.optionalString (cfg.identityFile != null) ''
        # the tasks run ssh with `-F none -i <key> -o IdentitiesOnly=yes`: no ssh_config is read, so this is the only key offered;
        # a missing key would otherwise surface as "unreachable" from every remote host
        [ -r ${lib.escapeShellArg cfg.identityFile} ] || { echo "coordinator: identity file ${cfg.identityFile} is missing or unreadable" >&2; exit 2; }
        export COORDINATOR_SSH_IDENTITY=${lib.escapeShellArg cfg.identityFile}
      ''}
      exec claude --agent coordinator --permission-mode default --setting-sources project --settings ${settingsFile} "$@"
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
  home.activation.coordinatorCheckout = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    wipe() { for d in "$@"; do [ -e "$d" ] || continue; run chmod -R u+w "$d" 2>/dev/null || true; run rm -rf "$d" || true; done; }
    # a copy the guard would refuse (manifest, pin, listed files, unlisted policy files) is rebuilt by the same
    # predicate, so activation repairs it instead of leaving the operator to wipe the directory by hand
    healthy() {
      local pin; pin=$(cat "${pinFile}" 2>/dev/null) || pin=""
      # the guard accepts only a 64-hex pin, so the activation must demand the same or a copy could stay refused
      [[ "$pin" =~ ^[0-9a-f]{64}$ ]] || { echo "coordinator: no valid integrity pin; rebuilding the checkout" >&2; return 1; }
      [ "$(cat "${checkout}/.complete" 2>/dev/null)" = "${layoutVersion}" ] || { echo "coordinator: checkout layout changed; rebuilding" >&2; return 1; }
      ${integrityCheck} "${checkout}" "$pin" coordinator 2>&1 | sed 's/^/coordinator: checkout rebuilt because: /' >&2
      [ "''${PIPESTATUS[0]}" -eq 0 ]
    }
    run mkdir -p "${checkoutRoot}" "${stateDir}" "${config.xdg.configHome}/coordinator"
    wipe "${checkoutRoot}"/skills-*.tmp
    if ! healthy; then
      wipe "${checkout}" "${checkout}.tmp"
      run cp -r "${skillsSrc}" "${checkout}.tmp"
      run chmod -R u+w "${checkout}.tmp"
      # project-scoped agent and skills: --setting-sources project does not load user-scope ~/.claude/agents; an empty,
      # read-only, manifest-listed project settings file leaves nothing for a later session to plant
      run mkdir -p "${checkout}.tmp/.claude/agents" "${checkout}.tmp/.claude/skills"
      run sh -c ${lib.escapeShellArg "printf '{}\n' > '${checkout}.tmp/.claude/settings.json'"}
      run ln -sfn ../../agents/coordinator.md "${checkout}.tmp/.claude/agents/coordinator.md"
      for sk in ${lib.concatStringsSep " " (map lib.escapeShellArg coordinatorSkills)}; do run ln -sfn "../../skills/$sk" "${checkout}.tmp/.claude/skills/$sk"; done
      # .integrity lets the guard refuse every task call once a contract, task, hook or devenv file in the copy changes;
      # its own hash is pinned outside the checkout, and the guarded files lose their write bits
      run bash -c ${lib.escapeShellArg "set -o pipefail; cd '${checkout}.tmp' && find -L ${rootsArg} -type f -print0 | sort -z | xargs -0 sha256sum > .integrity && sha256sum .integrity | cut -d' ' -f1 > '${pinFile}' && find -L ${rootsArg} .integrity -type f -exec chmod a-w {} +"}
      run sh -c ${lib.escapeShellArg "printf '%s' '${layoutVersion}' > '${checkout}.tmp/.complete'"}
      run mv "${checkout}.tmp" "${checkout}"
    fi
    run ln -sfn "${checkout}" "${checkoutRoot}/current"
    # keep the active copy plus the two newest others; each old copy pins a devenv closure via .devenv/gc
    { find "${checkoutRoot}" -mindepth 1 -maxdepth 1 -type d -name 'skills-*' -not -path "${checkout}" -printf '%T@ %p\n' 2>/dev/null \
      | sort -rn | tail -n +3 | cut -d' ' -f2- | while read -r old; do wipe "$old"; run rm -f "${config.xdg.configHome}/coordinator/$(basename "$old").integrity.sha256"; done; } || true
  '';
}
