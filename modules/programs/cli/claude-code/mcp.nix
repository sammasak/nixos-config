# Claude Code settings, plugins and NixOS fixes, injected into every host via
# home-manager.sharedModules. Takes the skills flake input as its
# first argument, so it is imported applied:
#   (import .../claude-code/mcp.nix inputs.skills)
skillsSrc:
{
  pkgs,
  lib,
  config,
  osConfig,
  ...
}:
let
  worker = osConfig.sam.herdr.worker;
  bulkReader = osConfig.sam.claude.bulkReader;
  # both or neither: an older skills pin evaluates and registers nothing
  shunt =
    bulkReader.enable
    && lib.all (h: builtins.pathExists "${skillsSrc}/hooks/${h}") [
      "shunt-check-read.sh"
      "shunt-check-bash-read.sh"
    ];
  spill =
    shunt && bulkReader.spillOutput && builtins.pathExists "${skillsSrc}/hooks/shunt-spill-output.sh";
  shuntHook = name: {
    type = "command";
    command = "PATH=${
      lib.makeBinPath [
        pkgs.jq
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.findutils
      ]
    }:$PATH ${skillsSrc}/hooks/${name}";
    timeout = 15;
  };
  telemetry = osConfig.sam.claude.telemetry;
  otel = telemetry.enable;
  # The sandbox posture (scrub, default mode) stays the host profile's: a guest's telemetry must not change it
  hostOtel = osConfig.sam.profile.nativeOtel && otel;
  relay = "http://127.0.0.1:4319";
  resourceAttributes = lib.concatStringsSep "," (
    lib.mapAttrsToList (k: v: "${k}=${v}") telemetry.resourceAttributes
  );
  workRef = otel && builtins.pathExists "${skillsSrc}/hooks/emit-work-ref.sh";
  workRefHook = {
    type = "command";
    command = "PATH=${
      lib.makeBinPath [
        pkgs.jq
        pkgs.coreutils
        pkgs.curl
        pkgs.git
      ]
    }:$PATH ${skillsSrc}/hooks/emit-work-ref.sh";
    timeout = 5;
  };
  # Claude reports user skills as custom_skill with the content flags off; this hook sends the name only
  skillUse = otel && builtins.pathExists "${skillsSrc}/hooks/emit-skill-use.sh";
  skillUseHook = {
    type = "command";
    command = "PATH=${
      lib.makeBinPath [
        pkgs.jq
        pkgs.coreutils
        pkgs.curl
      ]
    }:$PATH ${skillsSrc}/hooks/emit-skill-use.sh";
    timeout = 5;
  };
in
{
  programs.claude-code = {
    enable = true;
    package = pkgs.claude-code;

    # Delivered via the HM-generated plugin bundle: Claude Code ignores MCP
    # servers declared in settings.json.
    mcpServers.playwright = {
      type = "stdio";
      command = "${pkgs.playwright-mcp}/bin/playwright-mcp";
      args = [
        "--isolated"
        "--executable-path"
        "${pkgs.chromium}/bin/chromium"
        "--headless"
        "--sandbox"
      ];
    };

    # Headed sibling for interactive logins (e.g. BankID). --storage-state, NOT
    # --user-data-dir: playwright-mcp 0.0.80 is isolated-only and throws on the
    # latter; storage-state persists the signed-in session across Claude sessions.
    mcpServers."playwright-login" = {
      type = "stdio";
      command = "${pkgs.playwright-mcp}/bin/playwright-mcp";
      args = [
        "--executable-path"
        "${pkgs.chromium}/bin/chromium"
        "--storage-state"
        "${config.home.homeDirectory}/.local/share/claude-playwright-login/state.json"
        "--sandbox"
      ];
    };

    settings = {
      theme = "dark";
      model = "claude-opus-5-5";
      # Pre-answered: read-only settings.json means the prompt could never save.
      tui = "fullscreen";
      # Publishing to claude.ai is never wanted from these hosts.
      # https://code.claude.com/docs/en/artifacts#disable-artifacts
      enableArtifact = false;
      # Keeps the default mode these hosts had under scrubbing (below); 2.1.300
      # otherwise starts in auto. --dangerously-skip-permissions overrides it.
      permissions = lib.optionalAttrs hostOtel { defaultMode = "default"; };
    }
    // lib.optionalAttrs worker.enable {
      # Worker hosts only: a --dangerously-skip-permissions start no longer stops at the acknowledgment dialog
      # (2.1.300 ignores ~/.claude.json's bypassPermissionsModeAccepted); a session without the flag is unaffected.
      skipDangerousModePermissionPrompt = true;
      # #157: "Switch automatically" when safeguards flag a message; unset, every session stops at a dialog asking
      switchModelsOnFlag = true;
    }
    // {
      env = {
        DISABLE_ERROR_REPORTING = "1";
      }
      // lib.optionalAttrs hostOtel {
        # "1" forces every session to the default permission mode, ignoring
        # --dangerously-skip-permissions (claude-code 2.1.300). With "0", tools
        # inherit credential-shaped env and run outside the bubblewrap sandbox;
        # OTEL_* and CLAUDE_CODE_OAUTH_TOKEN are still withheld.
        CLAUDE_CODE_SUBPROCESS_ENV_SCRUB = "0";
      }
      // lib.optionalAttrs (!otel) {
        DISABLE_TELEMETRY = "1";
      }
      // lib.optionalAttrs otel {
        CLAUDE_CODE_ENABLE_TELEMETRY = "1";
        OTEL_METRICS_EXPORTER = "otlp";
        OTEL_LOGS_EXPORTER = "otlp";
        # The relay adds the gateway token: a headless `claude -p` from a script or another session's Bash
        # tool never passes a shell wrapper, so a token in the environment would miss it.
        OTEL_EXPORTER_OTLP_ENDPOINT = relay;
        OTEL_EXPORTER_OTLP_PROTOCOL = "http/protobuf";
        OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE = "cumulative";
        OTEL_RESOURCE_ATTRIBUTES = resourceAttributes;
        # On events only: the gateway strips session.id from metrics
        OTEL_METRICS_INCLUDE_SESSION_ID = "true";
        OTEL_METRICS_INCLUDE_REPOSITORY = "true";
        OTEL_METRICS_INCLUDE_ACCOUNT_UUID = "false";
        OTEL_LOG_USER_PROMPTS = "0";
        OTEL_LOG_TOOL_CONTENT = "0";
        OTEL_LOG_TOOL_DETAILS = "0";
        OTEL_LOG_RAW_API_BODIES = "0";
        # Claude strips OTEL_* from hook environments; emit-work-ref.sh and emit-skill-use.sh read these instead.
        HARNESS_OTLP_ENDPOINT = relay;
        HARNESS_RESOURCE_ATTRIBUTES = resourceAttributes;
      }
      // lib.optionalAttrs (shunt && bulkReader.minTokens != null) {
        SHUNT_MIN_TOKENS = toString bulkReader.minTokens;
      }
      // lib.optionalAttrs (shunt && bulkReader.model != null) {
        SHUNT_MODEL = bulkReader.model;
      };
      enabledPlugins = {
        # The complete intended set — anything not listed here is uninstalled.
        # Declared here because interactive `/plugin` toggles cannot save
        # against the read-only settings.json.
        "superpowers@claude-plugins-official" = true;
        "rust-analyzer-lsp@claude-plugins-official" = true;
        "frontend-design@claude-plugins-official" = true;
        # usageCount 2006 in ~/.claude.json: pruning it fought real daily use
        # (slash-command usage is invisible to Skill-invocation greps).
        "ralph-loop@claude-plugins-official" = true;
      };
      # Hook commands are Nix store paths from the skills input, so
      # they resolve on every host regardless of HOME.
      hooks = {
        Stop = [
          {
            hooks = [
              {
                type = "command";
                command = "${skillsSrc}/hooks/check-git-state.sh";
                timeout = 10;
              }
            ]
            ++ lib.optional workRef workRefHook;
          }
        ];
        PreToolUse = [
          {
            # 15s: p99 is ~0.8s, but a timed-out PreToolUse hook does NOT block,
            # so the budget clears the worst observed case (3.7s) with headroom.
            matcher = "Bash";
            hooks = [
              {
                type = "command";
                command = "${skillsSrc}/hooks/validate-bash.sh";
                timeout = 15;
              }
              {
                type = "command";
                command = "${skillsSrc}/hooks/check-loop.sh";
                timeout = 15;
              }
            ]
            # skills#28: a bypassPermissions worker has no classifier before `gh pr merge`; this refuses an
            # unreviewed or implementer merge (present once the skills pin carries it)
            ++ lib.optional (worker.enable && builtins.pathExists "${skillsSrc}/hooks/check-merge.sh") {
              type = "command";
              command = "PATH=${
                lib.makeBinPath [
                  pkgs.gh
                  pkgs.python3
                  pkgs.coreutils
                ]
              }:$PATH ${skillsSrc}/hooks/check-merge.sh";
              timeout = 30;
            }
            ++ lib.optional shunt (shuntHook "shunt-check-bash-read.sh");
          }
        ]
        ++ lib.optional shunt {
          matcher = "Read";
          hooks = [ (shuntHook "shunt-check-read.sh") ];
        }
        ++ lib.optional skillUse {
          matcher = "Skill";
          hooks = [ skillUseHook ];
        };
        PostToolUse =
          lib.optional spill {
            matcher = "Bash";
            hooks = [ (shuntHook "shunt-spill-output.sh") ];
          }
          ++ [
            {
              matcher = "Write|Edit";
              hooks = [
                {
                  type = "command";
                  command = "${skillsSrc}/hooks/validate-manifest.sh";
                  timeout = 30;
                }
                {
                  type = "command";
                  command = "${skillsSrc}/hooks/validate-nix.sh";
                  timeout = 30;
                }
                {
                  # PATH prefix: shellcheck is not in the user environment, and the
                  # hook skips silently when it cannot find the binary.
                  type = "command";
                  command = "PATH=${lib.makeBinPath [ pkgs.shellcheck ]}:$PATH ${skillsSrc}/hooks/validate-shell.sh";
                  timeout = 30;
                }
              ];
            }
          ];
      }
      // lib.optionalAttrs workRef {
        SessionStart = [ { hooks = [ workRefHook ]; } ];
      }
      // lib.optionalAttrs skillUse {
        UserPromptSubmit = [ { hooks = [ skillUseHook ]; } ];
      };
    };
  };

  # playwright-mcp does not create the --storage-state parent dir itself.
  home.file.".local/share/claude-playwright-login/.keep".text = "";

  # Keeps the enabledPlugins declaration true on disk: interactive /plugin
  # installs survive in mutable ~/.claude/plugins state, so anything not
  # declared is pruned from cache, data, and the installed list on activation.
  home.activation.prunePluginState =
    let
      declared = lib.attrNames config.programs.claude-code.settings.enabledPlugins;
      keep = lib.concatStringsSep "|" (map (p: lib.head (lib.splitString "@" p)) declared);
      keepMarketplaces = lib.concatStringsSep "|" (
        lib.unique (map (p: lib.last (lib.splitString "@" p)) declared)
      );
      script = pkgs.writeShellScript "prune-plugin-state" ''
        base="$HOME/.claude/plugins"
        [ -d "$base/cache" ] || exit 0
        for dir in "$base"/cache/*/*/; do
          [ -d "$dir" ] || continue
          name=$(basename "$dir")
          echo "$name" | grep -qE '^(${keep})$' && continue
          rm -rf "$dir"
        done
        for dir in "$base"/data/*/; do
          [ -d "$dir" ] || continue
          name=$(basename "$dir")
          echo "$name" | grep -qE '^(${keep})' || rm -rf "$dir"
        done
        rmdir "$base"/cache/*/ 2>/dev/null || true
        for dir in "$base"/marketplaces/*/; do
          [ -d "$dir" ] || continue
          name=$(basename "$dir")
          echo "$name" | grep -qE '^(${keepMarketplaces})$' || rm -rf "$dir"
        done
        if [ -f "$base/known_marketplaces.json" ]; then
          ${pkgs.jq}/bin/jq --arg keep '${keepMarketplaces}' \
            'with_entries(select(.key | test("^(" + $keep + ")$")))' \
            "$base/known_marketplaces.json" > "$base/.km.tmp" && mv "$base/.km.tmp" "$base/known_marketplaces.json"
        fi
        if [ -f "$base/installed_plugins.json" ]; then
          ${pkgs.jq}/bin/jq --arg keep '${keep}' \
            '.plugins |= with_entries(select(.key | split("@")[0] | test("^(" + $keep + ")$")))' \
            "$base/installed_plugins.json" > "$base/.ipj.tmp" && mv "$base/.ipj.tmp" "$base/installed_plugins.json"
          # Convergence is prune-only; installing needs an interactive /plugin
          # run, so a declared-but-missing plugin gets a loud line instead.
          # Marketplace-served plugins never enter installed_plugins.json, so
          # presence under marketplaces/*/plugins/ also counts as installed.
          for p in ${lib.concatStringsSep " " (map (p: lib.head (lib.splitString "@" p)) declared)}; do
            ${pkgs.jq}/bin/jq -e --arg p "$p" '.plugins | keys | map(split("@")[0]) | index($p)' \
              "$base/installed_plugins.json" >/dev/null 2>&1 && continue
            ls -d "$base"/marketplaces/*/plugins/"$p" >/dev/null 2>&1 && continue
            ls -d "$base"/marketplaces/*/"$p" >/dev/null 2>&1 && continue
            echo "claude-code: declared plugin '$p' is not installed — run /plugin install" >&2
          done
        fi
      '';
    in
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${script}
    '';

  # Live sessions keep enforcing the hook generation loaded at their start,
  # and the in-band Stop-hook warning only exists in NEW generations — so a
  # generation change also pings ntfy out-of-band (fail-open: no LAN, no ping).
  home.activation.notifyHookGeneration =
    let
      script = pkgs.writeShellScript "notify-hook-generation" ''
        state="$HOME/.local/state/claude-hooks/deployed-store"
        [ "$(cat "$state" 2>/dev/null)" = "${skillsSrc}" ] && exit 0
        mkdir -p "$(dirname "$state")"
        printf '%s' "${skillsSrc}" > "$state"
        ${pkgs.curl}/bin/curl -fsS -m 5 \
          -H "Title: Claude hooks updated" -H "Priority: min" -H "Tags: wrench" \
          -d "New hook generation ${skillsSrc} deployed; running Claude sessions enforce their start-time generation until restarted." \
          http://${osConfig.sam.fleet.hosts.lenovo-21CB001PMX.address}:2586/homelab-improvements >/dev/null 2>&1 || true
      '';
    in
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${script}
    '';

  # The four manual-.githooks repos carry the no-force guard only when
  # core.hooksPath=.githooks is set, and that config does NOT travel with a
  # clone — a fresh checkout runs no guard until set. Every machine runs HM
  # activation, so set it here for each repo that exists with a .githooks dir:
  # a fresh clone is guarded by its first rebuild. Idempotent, skips absent repos.
  home.activation.wireManualGitHooks =
    let
      wireScript = pkgs.writeShellScript "wire-manual-githooks" ''
        for r in nixos-config skills homelab-gitops knowledge; do
          d="$HOME/$r"
          [ -d "$d/.git" ] && [ -d "$d/.githooks" ] || continue
          cur=$(${pkgs.git}/bin/git -C "$d" config --local core.hooksPath 2>/dev/null || true)
          [ "$cur" = ".githooks" ] && continue
          ${pkgs.git}/bin/git -C "$d" config --local core.hooksPath .githooks || true
        done
      '';
    in
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${wireScript}
    '';

  # sops-nix decrypts to /run/secrets/claude_oauth_token (modules/core/sops.nix).
  # Literal path on purpose: this is an HM module, so config.sops.secrets — a
  # NixOS option — is not in scope. ~/.env is a local dev override only.
  programs.fish.interactiveShellInit = lib.mkAfter ''
    if test -f "$HOME/.env"
      and grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' "$HOME/.env" 2>/dev/null
      set -gx CLAUDE_CODE_OAUTH_TOKEN (grep '^CLAUDE_CODE_OAUTH_TOKEN=' "$HOME/.env" | cut -d= -f2-)
    end
    if test -f /run/secrets/claude_oauth_token
      set -gx CLAUDE_CODE_OAUTH_TOKEN (cat /run/secrets/claude_oauth_token)
    end
  '';

  # Pre-accepts the bypass-permissions, auto-mode nudge and $HOME project-trust
  # dialogs, which would otherwise reappear every launch (read-only
  # settings.json); a host also trusts its declared sam.herdr.trustedDirs.
  # Claude rewrites the file constantly: one that is not one JSON object (empty, half-written) is skipped with a
  # warning, since a failing activation fails the whole system switch.
  home.activation.acceptClaudeStartupDialogs =
    let
      script = pkgs.writeShellScript "accept-claude-startup-dialogs" ''
        stateFile="$HOME/.claude.json"
        if [ ! -f "$stateFile" ]; then
          echo '{}' > "$stateFile"
          chmod 600 "$stateFile"
        fi
        if ! ${pkgs.jq}/bin/jq -e -s 'length == 1 and (.[0] | type == "object")' "$stateFile" >/dev/null 2>&1; then
          echo "accept-claude-startup-dialogs: $stateFile is not one JSON object, leaving it alone" >&2
          exit 0
        fi
        tmp=$(mktemp "$stateFile.XXXXXX")
        trap 'rm -f "$tmp"' EXIT
        chmod 600 "$tmp"
        if ${pkgs.jq}/bin/jq \
          --arg home "$HOME" --argjson dirs ${lib.escapeShellArg (builtins.toJSON osConfig.sam.herdr.trustedDirs)} \
          '.bypassPermissionsModeAccepted = true | .hasSeenAutoDefaultNudge = true | .hasCompletedOnboarding = true | .lastOnboardingVersion //= "2.1.300" | .theme //= "dark" | .hasSeenAutoModeEntryWarning = true | reduce ([$home] + $dirs)[] as $d (.; .projects[$d].hasTrustDialogAccepted = true)' \
          "$stateFile" > "$tmp" 2>/dev/null; then
          mv "$tmp" "$stateFile"
        else
          echo "accept-claude-startup-dialogs: jq failed on $stateFile, leaving it alone" >&2
        fi
      '';
    in
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${script}
    '';

  # ── NixOS shebang fixes ──────────────────────────────────────────────
  # Patches #!/bin/bash → #!/usr/bin/env bash in plugin cache.
  # NixOS doesn't have /bin/bash; re-runs on rebuild to fix new/updated plugins.
  home.activation.fixClaudePluginShebangs =
    let
      script = pkgs.writeShellScript "fix-claude-plugin-shebangs" ''
        pluginDir="$HOME/.claude/plugins/cache"
        [ -d "$pluginDir" ] || exit 0
        find "$pluginDir" -name '*.sh' -type f | while read -r f; do
          head -1 "$f" | grep -qF '#!/bin/bash' && ${pkgs.gnused}/bin/sed -i '1s|^#!/bin/bash|#!/usr/bin/env bash|' "$f" || true
        done
      '';
    in
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${script}
    '';
}
