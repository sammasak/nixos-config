# Persistent terminal workspace for AI coding agents, on every host: every host
# runs a herdr server; the coordinator host also saves the workers as herdr
# machines (sam.herdr.machines) and reaches them with `herdr --machine <label>`.
{ config, lib, pkgs, osConfig, ... }:
let
  # delivery = "system" needs an OS notification daemon; the headless worker has
  # none, so it falls back to herdr's own in-app toasts (rendered in the client).
  toastDelivery = if (osConfig.sam.desktop.enable or false) then "system" else "herdr";
  herdrBin = lib.getExe pkgs.herdr;
  machines = osConfig.sam.herdr.machines or [ ];
  herdrAlreadyRunning = pkgs.writeShellScript "herdr-already-running" ''
    if ${herdrBin} status --json | ${lib.getExe pkgs.jq} -e '.server.running == true' >/dev/null 2>&1; then
      exit 1
    fi
    exit 0
  '';
  herdrAgentLauncher = pkgs.writeShellApplication {
    name = "herdr-agent-launcher";
    runtimeInputs = [ pkgs.coreutils pkgs.herdr pkgs.jq ];
    text = builtins.readFile ./agent-launcher.sh;
  };
  integrationFiles = pkgs.runCommand "herdr-agent-integrations" {
    nativeBuildInputs = [ pkgs.herdr ];
  } ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME/.claude" "$HOME/.codex" "$HOME/.pi/agent"
    ${herdrBin} integration install claude
    ${herdrBin} integration install codex
    ${herdrBin} integration install pi
    mkdir -p "$out/claude" "$out/codex" "$out/pi"
    cp "$HOME/.claude/hooks/herdr-agent-state.sh" "$out/claude/"
    cp "$HOME/.codex/herdr-agent-state.sh" "$out/codex/"
    cp "$HOME/.pi/agent/extensions/herdr-agent-state.ts" "$out/pi/"
  '';
in
{
  home.packages = [ pkgs.herdr pkgs.python3Minimal ];

  programs.fish.functions = {
    pi = ''
      command ${herdrAgentLauncher}/bin/herdr-agent-launcher pi $argv
    '';
    claude = ''
      command ${herdrAgentLauncher}/bin/herdr-agent-launcher claude $argv
    '';
    codex = ''
      command ${herdrAgentLauncher}/bin/herdr-agent-launcher codex $argv
    '';
  };

  home.file = {
    ".claude/hooks/herdr-agent-state.sh".source = "${integrationFiles}/claude/herdr-agent-state.sh";
    ".codex/herdr-agent-state.sh".source = "${integrationFiles}/codex/herdr-agent-state.sh";
  } // lib.optionalAttrs (osConfig.sam.profile.pi or false) {
    ".pi/agent/extensions/herdr-agent-state.ts".source = "${integrationFiles}/pi/herdr-agent-state.ts";
  };

  programs.claude-code.settings.hooks.SessionStart = [
    {
      matcher = "^(startup|resume|clear|compact|fork)$";
      hooks = [
        {
          type = "command";
          command = "bash ${config.home.homeDirectory}/.claude/hooks/herdr-agent-state.sh session";
          timeout = 10;
        }
      ];
    }
  ];

  # A read-only symlink means `herdr config reset-keys` / in-app edits cannot
  # persist; the config is owned here and reapplied on rebuild.
  xdg.configFile."herdr/config.toml".text = ''
    # Owned here because the config symlink is read-only: herdr cannot persist the
    # onboarding dismissal itself (it fails with "os error 30" on every start).
    onboarding = false

    [terminal]
    default_shell = "fish"

    [theme]
    name = "terminal"

    [ui]
    # Not the default dots: shapes stay readable regardless of theme colors.
    status_indicators = "symbols"

    [ui.toast]
    delivery = "${toastDelivery}"

    [session]
    resume_agents_on_restore = true

    [experimental]
    pane_history = true
  '';

  home.activation.herdrConfigPermissions = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    $DRY_RUN_CMD mkdir -p "$HOME/.config/herdr"
    $DRY_RUN_CMD chmod 700 "$HOME/.config/herdr"
    if [ -e "$HOME/.config/herdr/session-history.json" ]; then
      $DRY_RUN_CMD chmod 600 "$HOME/.config/herdr/session-history.json"
    fi
  '';

  # Added through herdr itself so its client state stays herdr-owned and mutable; a label herdr already
  # knows is skipped, and a failed add (host down, key missing) is reported but never stops activation.
  home.activation.herdrMachines = lib.mkIf (machines != [ ]) (lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    for spec in ${lib.concatMapStringsSep " " (m: lib.escapeShellArg "${m.label}=${m.target}") machines}; do
      label=''${spec%%=*}; target=''${spec#*=}
      if ${herdrBin} machine list --json 2>/dev/null | ${lib.getExe pkgs.jq} -e --arg l "$label" 'any(.[]?; .label == $l)' >/dev/null; then
        continue
      fi
      echo "herdr: saving machine $label ($target)"
      run ${pkgs.coreutils}/bin/timeout 30 ${herdrBin} machine add "$target" --label "$label" --remote-session default </dev/null \
        || echo "herdr: machine add $label failed; run by hand: herdr machine add $target --label $label --remote-session default" >&2
    done
  '');

  systemd.user.services.herdr = {
    Unit.Description = "Persistent Herdr session server";
    Service = {
      ExecCondition = herdrAlreadyRunning;
      ExecStart = "${herdrBin} server";
      Restart = "on-failure";
      RestartSec = 5;
      UMask = "0077";
    };
    Install.WantedBy = [ "default.target" ];
  };
}
