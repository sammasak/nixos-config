# Turn `devenv print-dev-env --json` data into a bounded guest-side activation.
# The JSON is produced by the trusted host preparer; the shell hook remains data
# here and is evaluated only by this command inside an agent-runtime instance.
{ lib, pkgs }:
{ envJson, profile, projectRoot, expectedRequest ? null, consumeRequest ? false }:
let
  envPath = toString envJson;
  profilePath = toString profile;
  requestMode = expectedRequest != null || consumeRequest;
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
      checkout_root=${lib.escapeShellArg projectRoot}
      repo=$checkout_root
      instance=''${AGENT_RUNTIME_INSTANCE:?not in an agent-runtime instance}

      # Requests supplied to `agent-runtime-instance start --request` arrive as
      # a separate read-only bind. Merge that data with the host-prepared
      # projection in guest tmpfs; project activation remains guest-only.
      if [ -n "''${AGENT_RUNTIME_EXECUTION_REQUEST:-}" ]; then
        [ -r "$AGENT_RUNTIME_EXECUTION_REQUEST" ] || {
          echo "execution request is not readable inside the instance" >&2
          exit 65
        }
        merged_json=$(mktemp "''${TMPDIR:-/tmp}/agent-runtime-devenv.XXXXXX")
        trap 'rm -f -- "$merged_json"' EXIT
        ${pkgs.jq}/bin/jq --slurpfile request "$AGENT_RUNTIME_EXECUTION_REQUEST" \
          '. + {executionRequest: $request[0]}' "$env_json" >"$merged_json"
        env_json=$merged_json
      fi

      # Validate the entire projection before activation. Host credentials and
      # host-local paths are never copied into the guest environment.
      ${pkgs.jq}/bin/jq -e --arg profile "$profile" \
        --argjson expected ${lib.escapeShellArg (builtins.toJSON expectedRequestData)} \
        --arg system ${lib.escapeShellArg (expectedRequestData.target_system or pkgs.stdenv.hostPlatform.system)} '
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
          and (.executionRequest.source.repo | type == "string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))
          and .executionRequest.source.url == ("https://github.com/" + .executionRequest.source.repo)
          and ($expected.repo == null or .executionRequest.source.repo == $expected.repo)
          and (.executionRequest.source.ref | type == "string" and length > 0 and length <= 255)
          and (.executionRequest.source.sha | type == "string" and test("^[0-9a-f]{40}$"))
          and ($expected.sha == null or .executionRequest.source.sha == $expected.sha)
          and (.executionRequest.source.root | type == "string" and length > 0 and length <= 1024 and
            (. == "." or ((test("[\\x00-\\x1f\\x7f\\\\]") | not) and (split("/") | all(. != "" and . != "." and . != "..")))))
          and ($expected.root == null or .executionRequest.source.root == $expected.root)
          and .executionRequest.environment.kind == "devenv"
          and (.executionRequest.environment.index | type == "number" and . >= 0 and floor == .)
          and ($expected.environment_index == null or .executionRequest.environment.index == $expected.environment_index)
          and .executionRequest.environment.root == .executionRequest.source.root
          and .executionRequest.environment.shell == "devenv"
          and .executionRequest.target_system == $system
          and (.executionRequest.provenance.plan_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
          and (.executionRequest.provenance.lockfiles | type == "array")
          and (.executionRequest.source.root as $root
            | (if $root == "." then "devenv.lock" else $root + "/devenv.lock" end) as $lock
            | ($expected.lockfile == null or $expected.lockfile == $lock)
              and ([.executionRequest.provenance.lockfiles[] | select(.path == $lock)] | length == 1)
              and any(.executionRequest.provenance.lockfiles[]; .path == $lock and (.blob | test("^[0-9a-f]{40}$"))))
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
      project_root_rel="$(${pkgs.jq}/bin/jq -er '.executionRequest.source.root' "$env_json")" || exit 65
      if [ "$project_root_rel" != "." ]; then
        repo="$checkout_root/$project_root_rel"
        resolved_repo="$(realpath -e -- "$repo")" || {
          echo "execution request rejected: selected project root is missing" >&2
          exit 65
        }
        if [ "$resolved_repo" != "$repo" ]; then
          echo "execution request rejected: selected project root is not canonical" >&2
          exit 65
        fi
      fi
      lockfile_rel="$(${pkgs.jq}/bin/jq -er '
        .executionRequest.source.root as $root
        | if $root == "." then "devenv.lock" else $root + "/devenv.lock" end
      ' "$env_json")" || exit 65
      lockfile="$checkout_root/$lockfile_rel"
      expected_blob="$(${pkgs.jq}/bin/jq -er --arg path "$lockfile_rel" \
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
