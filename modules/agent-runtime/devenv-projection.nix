# Turn `devenv print-dev-env --json` data into a bounded guest-side activation.
# The JSON is produced by the trusted host preparer; the shell hook remains data
# here and is evaluated only by this command inside an agent-runtime instance.
{ lib, pkgs }:
{ envJson, profile, projectRoot, expectedRequest ? null }:
let
  envPath = toString envJson;
  profilePath = toString profile;
  requestMode = expectedRequest != null;
  expectedRequestData = if requestMode then expectedRequest else { };
  ignored = [
    "BASHOPTS" "EUID" "HOME" "NIX_BUILD_TOP" "NIX_ENFORCE_PURITY" "NIX_LOG_FD" "NIX_REMOTE"
    "NIX_SSL_CERT_FILE" "OLDPWD" "PPID" "PWD" "SHELLOPTS" "SHLVL" "SSL_CERT_FILE" "TEMP"
    "TEMPDIR" "TERM" "TMPDIR" "TZ" "UID" "builder" "out" "outputs"
    "DEVENV_ROOT" "DEVENV_DOTFILE" "DEVENV_STATE" "DEVENV_RUNTIME" "shellHook"
  ];
  runner = pkgs.writeShellApplication {
    name = "agent-runtime-devenv-run";
    runtimeInputs = [ pkgs.bash pkgs.coreutils pkgs.git pkgs.jq ];
    text = ''
      set -euo pipefail
      env_json="''${1:-${lib.escapeShellArg envPath}}"
      [ "$#" -eq 0 ] || shift
      [ "$#" -eq 0 ] || { echo "usage: agent-runtime-devenv-run [projected-env.json]" >&2; exit 64; }
      profile=${lib.escapeShellArg profilePath}
      repo=${lib.escapeShellArg projectRoot}
      instance=''${AGENT_RUNTIME_INSTANCE:?not in an agent-runtime instance}

      # Validate the entire projection before activation. Host credentials and
      # host-local paths are never copied into the guest environment.
      ${pkgs.jq}/bin/jq -e --arg profile "$profile" \
        --argjson expected ${lib.escapeShellArg (builtins.toJSON expectedRequestData)} '
        def sensitive: test("(SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL|AUTH|API_KEY|PRIVATE_KEY|COOKIE|SSH_)"; "i");
        type == "object" and .schema_version == 1
        and (.variables | type == "object")
        and (.variables.DEVENV_PROFILE.type == "exported" and .variables.DEVENV_PROFILE.value == $profile and ($profile | startswith("/nix/store/")))
        and (.variables.DEVENV_ROOT.value == "__PROJECT_ROOT__")
        and (.variables.DEVENV_RUNTIME.value == "__DEVENV_RUNTIME__")
        and (.variables.shellHook.type == "exported" and (.variables.shellHook.value | type) == "string")
        and all(.variables | to_entries[];
          (.key | test("^[A-Za-z_][A-Za-z0-9_]*$"))
          and ((.key | sensitive) | not)
          and (.value.type != "exported" or (.value.value | type) == "string")
          and (.value.type != "exported" or (.value.value | test("/home/|/run/user/|/tmp/|/var/tmp/") | not)))
        and ${if requestMode then ''
          (.executionRequest | type == "object")
          and .executionRequest.schema_version == 1
          and .executionRequest.kind == "devenv-platform/execution-request"
          and .executionRequest.status == "ready"
          and .executionRequest.blockers == []
          and .executionRequest.source.repo == $expected.repo
          and .executionRequest.source.url == ("https://github.com/" + $expected.repo)
          and (.executionRequest.source.ref | type == "string" and length > 0 and length <= 255)
          and .executionRequest.source.sha == $expected.sha
          and .executionRequest.source.root == $expected.root
          and .executionRequest.environment.kind == "devenv"
          and .executionRequest.environment.index == $expected.environment_index
          and .executionRequest.environment.root == $expected.root
          and .executionRequest.environment.shell == "devenv"
          and .executionRequest.target_system == $expected.target_system
          and (.executionRequest.provenance.plan_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
          and ($expected.lockfile | type == "string" and length > 0 and (startswith("/") | not)
            and (test("[\\x00-\\x1f\\x7f\\\\]") | not)
            and (split("/") | all(. != "" and . != "." and . != "..")))
          and ([.executionRequest.provenance.lockfiles[] | select(.path == $expected.lockfile)] | length == 1)
          and any(.executionRequest.provenance.lockfiles[]; .path == $expected.lockfile and (.blob | test("^[0-9a-f]{40}$")))
          and (.executionRequest.check.argv | type == "array" and length > 0 and length <= 128
            and all(.[]; type == "string" and length > 0 and length <= 4096 and (test("[\\x00-\\x1f\\x7f]") | not)))
        '' else ''
          (.check | type == "string" and length > 0)
        ''}
      ' "$env_json" >/dev/null || {
        echo "devenv projection rejected: incomplete, blocked, mismatched, credential-bearing, or host-local input" >&2
        exit 65
      }

      ${if requestMode then ''
      # shellcheck disable=SC2016 # Nix emits this as a shell-escaped literal path.
      lockfile="$repo"/${lib.escapeShellArg expectedRequestData.lockfile}
      # shellcheck disable=SC2016 # Nix emits this as a shell-escaped jq argument.
      expected_blob="$(${pkgs.jq}/bin/jq -er --arg path ${lib.escapeShellArg expectedRequestData.lockfile} \
        '[.executionRequest.provenance.lockfiles[] | select(.path == $path) | .blob] | if length == 1 then .[0] else error("missing or duplicate lockfile provenance") end' \
        "$env_json")" || exit 65
      if [ -L "$lockfile" ] || [ ! -f "$lockfile" ] || [ "$(git hash-object "$lockfile")" != "$expected_blob" ]; then
        echo "execution request rejected: lockfile blob differs from the pinned source" >&2
        exit 65
      fi
      '' else ""}

      mkdir -p "$repo/.devenv/state"
      export DEVENV_ROOT="$repo"
      export DEVENV_DOTFILE="$repo/.devenv"
      export DEVENV_STATE="$repo/.devenv/state"
      export DEVENV_RUNTIME="''${TMPDIR:-/tmp}/devenv-$instance"
      mkdir -p "$DEVENV_RUNTIME"
      cd "$repo"

      exports="$(${pkgs.jq}/bin/jq -er \
        --arg root "$repo" --arg runtime "$DEVENV_RUNTIME" \
        --argjson ignored '${builtins.toJSON ignored}' '
          .variables | to_entries[]
          | select(.value.type == "exported")
          | select((.key as $key | $ignored | index($key)) == null)
          | "export " + .key + "=" + (.value.value | split("__PROJECT_ROOT__") | join($root) | split("__DEVENV_RUNTIME__") | join($runtime) | @sh)
        ' "$env_json")" || exit 65
      eval "$exports"
      unset exports

      # The generated enterShell is executed once, after the environment has
      # been rebased to the guest paths and inside its nspawn boundary.
      hook="$(${pkgs.jq}/bin/jq -er \
        --arg root "$repo" --arg runtime "$DEVENV_RUNTIME" \
        '.variables.shellHook.value | split("__PROJECT_ROOT__") | join($root) | split("__DEVENV_RUNTIME__") | join($runtime)' \
        "$env_json")" || exit 65
      eval "$hook"
      unset hook
      # Devenv's generated shell hook may unset Nix build variables such as
      # `out`; capture the runtime output directory after hook activation.
      output_dir=''${AGENT_RUNTIME_OUTPUT:?not in an agent-runtime instance}

      ${if requestMode then ''
      argv=()
      while IFS= read -r -d $'\0' arg; do argv+=("$arg"); done < <(
        ${pkgs.jq}/bin/jq -j '.executionRequest.check.argv[] | ., "\u0000"' "$env_json"
      )
      [ "''${#argv[@]}" -gt 0 ] || exit 65
      rc=0
      "''${argv[@]}" >"$output_dir/check.log" 2>&1 || rc=$?
      '' else ''
      check="$(${pkgs.jq}/bin/jq -er '.check | strings' "$env_json")" || exit 65
      rc=0
      bash --noprofile --norc -euo pipefail -c "$check" >"$output_dir/check.log" 2>&1 || rc=$?
      ''}
      ${pkgs.jq}/bin/jq -n --arg marker "''${PROJECT_NATIVE_MARKER:-}" --arg import "''${PROJECT_NATIVE_IMPORT:-}" \
        --arg profile "$profile" --argjson check_exit "$rc" \
        '{environment: {marker: $marker, imported: $import, profile: $profile}, check_exit: $check_exit}' >"$output_dir/result.json"
      cat "$output_dir/check.log"
      exit "$rc"
    '';
  };
in
{
  inherit runner;
  inherit profilePath;
}
