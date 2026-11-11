# The host's own Claude Code as an interactive session in an instance: the same `pkgs.claude-code`
# and the same Home Manager-rendered CLAUDE.md, skills, agents, hooks and settings the host user
# runs, on a disposable pinned repository, under the runtime's PTY so the session user can watch and
# type (docs/agent-runtime-session.md). No wrapper program: the payload is `claude` itself.
# Host-only: it reads the importing host's Home Manager, so it has no standalone evaluation.
{ config, lib, pkgs, ... }:
let
  src = config.sam.agentRuntime.pinnedSources;
  t = config.sam.agentRuntime.templates.claude-session;
  repo = t.repositories.rf-proto.path;
  hm = config.home-manager.users.${config.sam.profile.username};
  claude = hm.programs.claude-code.package;
  hostHome = hm.home.homeDirectory;

  # CLAUDE.md, every skill (the Home Manager MCP plugin directory among them) and every agent, at
  # the host's store paths. Not settings.json (regenerated below) nor the host-only hooks directory.
  carried = lib.filter (
    f: f.enable && lib.any (p: lib.hasPrefix p f.target) [ ".claude/CLAUDE.md" ".claude/skills/" ".claude/agents/" ]
  ) (lib.attrValues hm.home.file);

  host = hm.programs.claude-code.settings;
  # a hook naming a path in the host user's home has nothing to run in the instance
  portable = h: !(lib.hasInfix "${hostHome}/" (h.command or ""));
  hooks = lib.filterAttrs (_: groups: groups != [ ]) (
    lib.mapAttrs (
      _: groups: lib.filter (g: g.hooks != [ ]) (map (g: g // { hooks = lib.filter portable (g.hooks or [ ]); }) groups)
    ) (host.hooks or { })
  );
  settings = host // {
    inherit hooks;
    # the instance is the sandbox: the session runs in bypass mode and must not stop at its dialog
    skipDangerousModePermissionPrompt = true;
    env = lib.filterAttrs (n: _: !(lib.hasPrefix "OTEL_" n)) (host.env or { }) // {
      DISABLE_TELEMETRY = "1";
      DISABLE_ERROR_REPORTING = "1";
    };
    permissions = (host.permissions or { }) // {
      deny = (host.permissions.deny or [ ]) ++ [ "Read(//run/agent-runtime/credentials/**)" ];
    };
  };
  # onboarding and the workdir's trust dialog answered, or the first screen is a wizard; a copy,
  # because Claude Code rewrites this file
  state = {
    hasCompletedOnboarding = true;
    lastOnboardingVersion = claude.version;
    bypassPermissionsModeAccepted = true;
    projects.${repo} = {
      hasTrustDialogAccepted = true;
      hasCompletedProjectOnboarding = true;
    };
  };
in
{
  sam.agentRuntime.templates.claude-session = {
    role = {
      name = "rust-worker";
      harness = "claude-code";
    };
    repositories.rf-proto = {
      github = "sammasak/rf-proto";
      ref = {
        type = "commit";
        value = src.rf-proto.rev;
      };
      lock = src.rf-proto;
      path = "/workspace/rf-proto";
      writable = true;
    };
    skillsSource = src.skills;
    skills.rust-engineering = { };
    # claude first: the manifest entrypoint. The rest is what the host's hooks and skills call.
    packages = [ claude ] ++ (with pkgs; [
      bash coreutils findutils gnugrep gnused gawk git jq ripgrep fd hostname less which diffutils gnutar gzip curl
      cargo rustc gcc
    ]);
    session = {
      enable = true;
      args = [ "--dangerously-skip-permissions" ];
      credentialEnv = "CLAUDE_CODE_OAUTH_TOKEN";
      workdir = repo;
      # Herdr names a pane's agent after its foreground process: under this name it tracks the
      # session as a native Claude agent (state, `herdr agent prompt`)
      paneProcessName = "claude";
    };
    environment = {
      # the only traffic is the API itself. Not SUBPROCESS_ENV_SCRUB=1: its tool sandbox drops
      # placeholder files into the repository (docs/agent-runtime-coder.md)
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
      CLAUDE_CODE_SUBPROCESS_ENV_SCRUB = "0";
      DISABLE_AUTOUPDATER = "1";
      CARGO_HOME = "${t.filesystem.cache.path}/cargo";
      CARGO_TARGET_DIR = "${t.filesystem.cache.path}/target";
    };
    homeFiles = lib.listToAttrs (map (f: lib.nameValuePair f.target { source = "${f.source}"; }) carried) // {
      ".claude/settings.json".source = "${pkgs.writeText "claude-session-settings.json" (builtins.toJSON settings)}";
      ".claude.json" = {
        source = "${pkgs.writeText "claude-session-state.json" (builtins.toJSON state)}";
        mode = "copy";
      };
    };
    filesystem = {
      workspaceBudget = { sizeMiB = 256; inodes = 20000; };
      home = { sizeMiB = 1024; inodes = 40000; };
      tmp = { sizeMiB = 1024; inodes = 40000; };
      cache = { sizeMiB = 2048; inodes = 40000; };
      output = { sizeMiB = 64; inodes = 100; };
    };
    resources = {
      cpus = 2;
      memoryMiB = 4096;
      tasksMax = 512;
      timeoutMinutes = 240;
    };
    # network.allow stays null (a host names the API host) and capabilities empty (no GitHub token)
  };
}
