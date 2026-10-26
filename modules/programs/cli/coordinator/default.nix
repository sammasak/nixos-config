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
  # The portable rules name ~/.local/state/coordinator; render the real state dir.
  renderRule = r: builtins.replaceStrings [ "~/.local/state/coordinator" ] [ stateDir ] r;
  settings = {
    permissions = {
      allow = map renderRule permissions.allow;
      ask = map renderRule permissions.ask;
      deny = map renderRule permissions.deny;
      defaultMode = "default";
    };
    # Fail closed even if the agent file's frontmatter were ignored: same guard at settings level.
    hooks.PreToolUse = [{
      matcher = "Bash";
      hooks = [{ type = "command"; command = "${home}/.claude/hooks/validate-coordinator.sh"; timeout = 10; }];
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
    text = ''
      export COORDINATOR_CHECKOUT=${checkout}
      cd "$COORDINATOR_CHECKOUT"
      [ -x "$HOME/.claude/hooks/validate-coordinator.sh" ] || { echo "coordinator: guard hook missing; refusing to start" >&2; exit 2; }
      exec claude --agent coordinator --permission-mode default --settings ${settingsFile} "$@"
    '';
  };
in
{
  assertions = [
    { assertion = osConfig.sam.profile.devTools; message = "sam.profile.coordinator needs devTools (claude-code, herdr)."; }
    { assertion = cfg.fleet.hosts != [ ]; message = "sam.coordinator.fleet.hosts must list at least the local host."; }
  ];

  home.packages = [ launcher ];

  home.file.".claude/hooks/validate-coordinator.sh".source = "${skillsSrc}/hooks/validate-coordinator.sh";
  xdg.configFile."coordinator/fleet.json".text = builtins.toJSON fleet;

  # devenv needs a writable project dir (.devenv/, eval cache), so the pinned
  # store copy is materialised once per skills revision; older copies stay for
  # rollback and the `current` link follows the active generation.
  home.activation.coordinatorCheckout = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ ! -d "${checkout}" ]; then
      run mkdir -p "${checkoutRoot}" "${stateDir}"
      run cp -r --no-preserve=mode "${skillsSrc}" "${checkout}"
    fi
    run ln -sfn "${checkout}" "${checkoutRoot}/current"
  '';
}
