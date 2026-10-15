# Imported applied, for hosts with sam.profile.pi (flake-modules/40-outputs-nixos.nix):
#   (import .../pi inputs.devenv-platform)
# The host still declares the sops secrets named in providerKeys
# (see hosts/lenovo-21CB001PMX/configuration.nix). Auth, upgrade, rollback: docs/pi.md.
devenvPlatform:
{ config, lib, pkgs, ... }:
let
  cfg = config.sam.pi;

  # Literal /run/secrets paths: this is an HM module, so the NixOS
  # config.sops.secrets is not in scope. A missing file just leaves the var unset.
  providerKeys = {
    GROQ_API_KEY = "groq_pi_agent_api_key";
    CLOUDFLARE_API_KEY = "cloudflare_pi_agent_workers_ai_token";
    CLOUDFLARE_ACCOUNT_ID = "cloudflare_account_id";
    GEMINI_API_KEY = "gemini_api_key";
    CEREBRAS_API_KEY = "cerebras_api_key";
  };

  fishExports = lib.concatStrings (lib.mapAttrsToList (var: secret: ''
    if test -r /run/secrets/${secret}
      set -gx ${var} (cat /run/secrets/${secret})
    end
  '') providerKeys);

  bashExports = lib.concatStrings (lib.mapAttrsToList (var: secret: ''
    if [ -r /run/secrets/${secret} ]; then
      export ${var}="$(cat /run/secrets/${secret})"
    fi
  '') providerKeys);

  # router/free plus the only model that passed multi-turn Rust tasks; Groq free
  # tier went 0/6 (TPM 429s, tool-schema rejects), see docs/pi.md.
  defaultSettings = builtins.toJSON {
    enabledModels = [
      "router/free"
      "cloudflare-workers-ai/@cf/qwen/qwen3.8-27b"
    ];
    # Free-tier 429s carry ~10-60s resets; the 2s default base gives up first.
    retry = {
      maxRetries = 5;
      baseDelayMs = 5000;
    };
  };

  # Pi rewrites settings.json (/model, /settings), so seed missing top-level
  # keys into the writable file instead of symlinking a read-only one over it.
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
    ${pkgs.jq}/bin/jq --argjson d ${lib.escapeShellArg defaultSettings} '$d + .' "$f" > "$tmp"
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
    ${pkgs.jq}/bin/jq --argjson p ${lib.escapeShellArg msiOllamaProvider} '.providers["msi-ollama"] = $p' "$f" > "$tmp"
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

    programs.bash.enable = true;
    programs.bash.initExtra = lib.mkAfter bashExports;
    programs.fish.interactiveShellInit = lib.mkAfter fishExports;
  };
}
