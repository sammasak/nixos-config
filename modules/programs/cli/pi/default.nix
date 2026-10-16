# Imported applied, for hosts with sam.profile.pi (flake-modules/40-outputs-nixos.nix):
#   (import .../pi inputs.devenv-platform)
# No provider key reaches the host: the in-cluster llm-gateway holds them. Auth, upgrade,
# rollback: docs/pi.md.
devenvPlatform:
{ config, lib, pkgs, ... }:
let
  cfg = config.sam.pi;

  # Seeded only when missing.
  defaultSettings = builtins.toJSON {
    # Free-tier 429s carry ~10-60s resets; the 2s default base gives up first.
    retry = {
      maxRetries = 5;
      baseDelayMs = 5000;
    };
  };

  # Re-applied on every activation: the in-cluster llm-gateway is the default
  # path (sammasak/llm-gateway#8); router/free stays selectable as the fallback.
  pinnedSettings = builtins.toJSON {
    defaultProvider = "homelab";
    defaultModel = "auto";
    enabledModels = [
      "homelab/auto"
      "homelab/best"
      "homelab/local"
      "router/free"
    ];
  };

  # Pi rewrites settings.json (/model, /settings), so seed missing top-level
  # keys (and re-pin the default model) into the writable file instead of
  # symlinking a read-only one over it.
  # A malformed user file is skipped, not fatal: it must not abort HM activation.
  seedPiSettings = pkgs.writeShellScript "seed-pi-settings" ''
    set -eu
    f="$HOME/.pi/agent/settings.json"
    mkdir -p "$(dirname "$f")"
    [ -f "$f" ] || echo '{}' > "$f"
    if ! ${pkgs.jq}/bin/jq -e 'type == "object"' "$f" >/dev/null 2>&1; then
      echo "seed-pi-settings: $f is not a JSON object, leaving it alone" >&2
      exit 0
    fi
    tmp="$(mktemp "$f.XXXXXX")"
    trap 'rm -f "$tmp"' EXIT
    ${pkgs.jq}/bin/jq --argjson d ${lib.escapeShellArg defaultSettings} --argjson p ${lib.escapeShellArg pinnedSettings} '$d + . + $p' "$f" > "$tmp"
    cmp -s "$tmp" "$f" || mv "$tmp" "$f"
  '';

  # router/free tier 3 (local): msi's CPU-only Ollama. Its own provider key, so the
  # hand-written providers in models.json (e.g. `ollama` for pi-harness) are kept;
  # only `msi-ollama` is replaced on every activation. contextWindow is the
  # server's OLLAMA_CONTEXT_LENGTH: Ollama truncates longer prompts silently.
  msiOllamaProvider = builtins.toJSON {
    baseUrl = cfg.msiOllamaBaseUrl;
    api = "openai-completions";
    apiKey = "ollama";
    models = map (id: {
      inherit id;
      contextWindow = 16384;
      maxTokens = 4096;
      compat = {
        supportsDeveloperRole = false;
        supportsReasoningEffort = false;
      };
    }) [ "qwen2.5-coder:7b" "llama3.1:8b" ];
  };

  # The default (`homelab/auto`, pinned above): the in-cluster llm-gateway picks a free model
  # by tier and fails over. `!cat` reads the sops key per request, so it never
  # enters the store or the environment.
  homelabProvider = builtins.toJSON {
    baseUrl = cfg.llmGatewayBaseUrl;
    api = "openai-completions";
    apiKey = "!cat /run/secrets/llm_gateway_pi_key";
    models = [
      { id = "auto"; name = "homelab auto"; reasoning = true; contextWindow = 1048576; maxTokens = 32768; }
      { id = "best"; name = "homelab best"; reasoning = true; contextWindow = 1048576; maxTokens = 32768; }
      { id = "local"; name = "homelab local"; contextWindow = 131072; maxTokens = 8192; }
    ];
    # One request shape every tier accepts: msi Ollama 400s on `reasoning_effort`
    # (rejected by both models, so `auto`/`local` lose the local floor) and Gemini
    # on `store`; `system`, not `developer`. x-session-id pins tool loops to a model.
    compat = {
      supportsStore = false;
      supportsReasoningEffort = false;
      supportsDeveloperRole = false;
      maxTokensField = "max_tokens";
      sendSessionAffinityHeaders = true;
      sessionAffinityFormat = "openrouter";
    };
  };

  # Same rules as seedPiSettings: a malformed user file is left alone.
  mergePiModels = pkgs.writeShellScript "merge-pi-models" ''
    set -eu
    f="''${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/models.json"
    mkdir -p "$(dirname "$f")"
    [ -f "$f" ] || echo '{}' > "$f"
    if ! ${pkgs.jq}/bin/jq -e 'type == "object" and ((.providers // {}) | type == "object")' "$f" >/dev/null 2>&1; then
      echo "merge-pi-models: $f is not a models.json object, leaving it alone" >&2
      exit 0
    fi
    tmp="$(mktemp "$f.XXXXXX")"
    trap 'rm -f "$tmp"' EXIT
    ${pkgs.jq}/bin/jq --argjson p ${lib.escapeShellArg msiOllamaProvider} --argjson h ${lib.escapeShellArg homelabProvider} \
      '.providers["msi-ollama"] = $p | .providers.homelab = $h' "$f" > "$tmp"
    chmod --reference="$f" "$tmp"
    cmp -s "$tmp" "$f" || mv "$tmp" "$f"
  '';

  # monitoring/loki ClusterIP: reachable from k3s nodes only; update if the Service is
  # recreated. Baked into the wrappers so non-login shells and timers get it too.
  lokiDefault = ''
    export PI_OFFLOAD_LOKI_URL="''${PI_OFFLOAD_LOKI_URL:-http://10.43.92.124:3100}"
  '';
in
{
  options.sam.pi.msiOllamaBaseUrl = lib.mkOption {
    type = lib.types.str;
    # ollama-msi-backend ClusterIP (llm ns): reachable from k3s nodes; update if the Service is recreated.
    default = "http://10.43.160.41:11434/v1";
    description = "OpenAI-compatible base URL of msi's Ollama, the router/free local tier.";
  };

  options.sam.pi.llmGatewayBaseUrl = lib.mkOption {
    type = lib.types.str;
    # Pinned spec.clusterIP in homelab-gitops apps/llm-gateway/service.yaml; reachable from k3s nodes.
    default = "http://10.43.0.80:8080/v1";
    description = "OpenAI-compatible base URL of the in-cluster llm-gateway (Pi provider `homelab`).";
  };

  config = {
    home.packages = [
      pkgs.pi-coding-agent
      (pkgs.writeShellApplication {
        name = "pi-offload";
        runtimeInputs = with pkgs; [ git jq coreutils util-linux curl openssh ];
        text = lokiDefault + builtins.readFile "${devenvPlatform}/agents/pi/offload/pi-offload";
      })
      (pkgs.writeShellApplication {
        name = "pi-view";
        runtimeInputs = with pkgs; [ curl jq coreutils ];
        text = lokiDefault + builtins.readFile "${devenvPlatform}/agents/pi/offload/pi-view";
      })
    ];

    # A store symlink: Pi only reads it, and updates arrive via `just bump devenv-platform`.
    home.file.".pi/agent/extensions/router-free".source = "${devenvPlatform}/agents/pi/router-free";

    home.sessionVariables = {
      PI_SKIP_VERSION_CHECK = "1";
      PI_TELEMETRY = "0";
    };

    home.activation.seedPiSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${seedPiSettings}
    '';

    home.activation.mergePiModels = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${mergePiModels}
    '';
  };
}
