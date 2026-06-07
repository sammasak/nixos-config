skillsSrc:
{ lib, pkgs, ... }:
let
  portableSkillNames = [
    "claude-ctl"
    "clean-code-principles"
    "container-workflows"
    "credentials"
    "knowledge-vault"
    "kubernetes-gitops"
    "nix-flake-development"
    "observability-patterns"
    "python-agentic-development"
    "python-engineering"
    "rust-engineering"
    "secrets-management"
  ];

  mkSkillLinks =
    prefix:
    builtins.listToAttrs (map
      (name: {
        name = "${prefix}/${name}";
        value = {
          source = "${skillsSrc}/skills/${name}";
        };
      })
      portableSkillNames);

  workspaceRoutingSkill = {
    source = ./workspace-routing;
    recursive = true;
  };

  codexSkillSync = pkgs.writeShellApplication {
    name = "codex-sync-skills";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gawk
      pkgs.gnugrep
    ];
    text = builtins.readFile ./sync-codex-skills.sh;
  };

  codexContextHook = pkgs.writeShellApplication {
    name = "codex-workspace-context-hook";
    runtimeInputs = [ pkgs.jq pkgs.gawk pkgs.coreutils ];
    text = builtins.readFile ./context-hook.sh;
  };

  codexValidateBashHook = pkgs.writeShellApplication {
    name = "codex-validate-bash-hook";
    runtimeInputs = [ pkgs.jq pkgs.gnugrep pkgs.gawk pkgs.coreutils ];
    text = builtins.readFile ./validate-bash.sh;
  };

  hooksConfig = builtins.toJSON {
    hooks = {
      SessionStart = [
        {
          hooks = [
            {
              type = "command";
              command = "${codexContextHook}/bin/codex-workspace-context-hook";
            }
          ];
        }
      ];
      UserPromptSubmit = [
        {
          hooks = [
            {
              type = "command";
              command = "${codexContextHook}/bin/codex-workspace-context-hook";
            }
          ];
        }
      ];
      PreToolUse = [
        {
          matcher = "Bash";
          hooks = [
            {
              type = "command";
              command = "${codexValidateBashHook}/bin/codex-validate-bash-hook";
            }
          ];
        }
      ];
    };
  };

  codexConfig = ''
    personality = "pragmatic"
    model = "gpt-5.4"
    model_reasoning_effort = "xhigh"
    approvals_reviewer = "user"
    check_for_update_on_startup = false
    cli_auth_credentials_store = "file"
    project_doc_fallback_filenames = ["CLAUDE.md", "CONTEXT.md"]
    project_doc_max_bytes = 65536

    [features]
    codex_hooks = true

    [projects."/home/lukas"]
    trust_level = "trusted"

    [notice]
    hide_full_access_warning = true

    [notice.model_migrations]
    "gpt-5.3-codex" = "gpt-5.4"

    [mcp_servers.playwright]
    enabled = true
    command = "${pkgs.playwright-mcp}/bin/mcp-server-playwright"
    args = ["--user-data-dir", "/tmp/playwright-mcp-profile", "--executable-path", "${pkgs.chromium}/bin/chromium", "--headless", "--no-sandbox"]
    startup_timeout_sec = 20
  '';

  seedCodexAuth = pkgs.writeShellScript "seed-codex-auth" ''
    set -eu

    auth_file="$HOME/.codex/auth.json"
    secret_file="/run/secrets/openai_api_key"

    if [ -f "$auth_file" ] || [ ! -f "$secret_file" ]; then
      exit 0
    fi

    cat "$secret_file" | ${pkgs.codex}/bin/codex login --with-api-key >/dev/null 2>&1 || true
  '';
in
{
  home.packages = [ pkgs.codex ];

  home.file =
    (mkSkillLinks ".agents/skills")
    // (mkSkillLinks ".codex/skills")
    // {
      ".agents/skills/workspace-routing" = workspaceRoutingSkill;
      ".codex/skills/workspace-routing" = workspaceRoutingSkill;
      ".codex/config.toml".text = codexConfig;
      ".codex/hooks.json".text = hooksConfig;
      ".codex/AGENTS.md".text = ''
        # Personal Codex Defaults

        - Treat `~/workspace` as the active knowledge graph and route through `~/workspace/CLAUDE.md` when a task references your projects or rooms.
        - Prefer the shared skills in `~/.agents/skills`, then the Codex-local overlay in `~/.codex/skills` for workspace workflows and Codex-compatible projections of `~/claude-code-skills/skills`.
        - When working inside `~/workspace`, load the nearest room `CONTEXT.md`; use `INDEX.md` only when `CONTEXT.md` is absent.
        - When a task names a workflow or `claude-code-skills`, route through `~/workspace/CLAUDE.md` and load the owning room `CONTEXT.md`.
        - Keep Codex and Claude aligned on bash safety: avoid force pushes, avoid encrypting SOPS payloads from `/tmp`, and follow the workspace guardrails.
      '';
    };

  home.activation.seedCodexAuth = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${seedCodexAuth}
  '';

  home.activation.syncCodexSkills = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${codexSkillSync}/bin/codex-sync-skills
  '';

  programs.bash.enable = true;
  programs.bash.initExtra = lib.mkAfter ''
    if [ -f /run/secrets/openai_api_key ]; then
      export OPENAI_API_KEY="$(cat /run/secrets/openai_api_key)"
    elif [ -f "$HOME/.env" ] && grep -q '^OPENAI_API_KEY=' "$HOME/.env" 2>/dev/null; then
      export OPENAI_API_KEY="$(grep '^OPENAI_API_KEY=' "$HOME/.env" | cut -d= -f2-)"
    fi
  '';

  programs.fish.interactiveShellInit = lib.mkAfter ''
    if test -f /run/secrets/openai_api_key
      set -gx OPENAI_API_KEY (cat /run/secrets/openai_api_key)
    else if test -f "$HOME/.env"
      and grep -q '^OPENAI_API_KEY=' "$HOME/.env" 2>/dev/null
      set -gx OPENAI_API_KEY (grep '^OPENAI_API_KEY=' "$HOME/.env" | cut -d= -f2-)
    end
  '';

  home.activation.cleanCodexSkills = lib.hm.dag.entryBefore [ "writeBoundary" ] ''
    skill_dir="$HOME/.codex/skills"
    manifest_file="$skill_dir/.codex-generated.manifest"
    set -e
    mkdir -p "$skill_dir"
    for name in ${lib.concatStringsSep " " portableSkillNames}; do
      target="$skill_dir/$name"
      if [ -e "$target" ]; then
        rm -rf "$target"
      fi
    done
    if [ -f "$manifest_file" ]; then
      while IFS= read -r name; do
        target="$skill_dir/$name"
        if [ -d "$target" ] && [ ! -L "$target" ]; then
          rm -rf "$target"
        fi
      done < "$manifest_file"
      rm -f "$manifest_file"
    fi
  '';
}
