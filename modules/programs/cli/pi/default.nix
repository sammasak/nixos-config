# Opt-in per host: import into the host's Home Manager user and declare the sops
# secrets named in providerKeys (see hosts/lenovo-21CB001PMX/configuration.nix).
# Distribution, auth, upgrade and rollback: docs/pi.md.
{ lib, pkgs, ... }:
let
  # Literal /run/secrets paths: this is an HM module, so the NixOS
  # config.sops.secrets is not in scope. A missing file just leaves the var unset.
  providerKeys = {
    GROQ_API_KEY = "groq_api_key";
    CLOUDFLARE_API_KEY = "cloudflare_workers_ai_token";
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

  # Free-tier models that authenticate on the pinned build; only the Cloudflare
  # one finishes multi-turn tool use, Groq's 8k TPM cap 429s it (docs/pi.md).
  defaultSettings = builtins.toJSON {
    enabledModels = [
      "cloudflare-workers-ai/@cf/qwen/qwen3.8-27b"
      "groq/openai/gpt-oss-120b"
      "groq/openai/gpt-oss-20b"
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
in
{
  home.packages = [ pkgs.pi-coding-agent ];

  home.sessionVariables = {
    PI_SKIP_VERSION_CHECK = "1";
    PI_TELEMETRY = "0";
  };

  home.activation.seedPiSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${seedPiSettings}
  '';

  programs.bash.enable = true;
  programs.bash.initExtra = lib.mkAfter bashExports;
  programs.fish.interactiveShellInit = lib.mkAfter fishExports;
}
