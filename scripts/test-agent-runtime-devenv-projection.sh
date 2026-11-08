#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
fixture="$repo_root/tests/fixtures/native-devenv-projection"
test_root=$(mktemp -d /tmp/agent-runtime-devenv-projection.XXXXXX)
trap 'rm -rf "$test_root"' EXIT
project="$test_root/project"
mkdir -p "$project"
cp -R "$fixture"/. "$project/"
chmod -R u+w "$project"

version=$(env -u DEVENV_ROOT -u DEVENV_DOTFILE -u DEVENV_STATE -u DEVENV_PROFILE -u DEVENV_RUNTIME devenv --version | awk '{print $2}')
[ "$version" = 2.4.0 ] || { echo "expected devenv 2.4.0, got $version" >&2; exit 1; }
lock_before=$(sha256sum "$project/devenv.lock" | awk '{print $1}')
inputs=$(FIXTURE_LOCK="$project/devenv.lock" nix eval --impure --json --expr '
  let
    lock = builtins.fromJSON (builtins.readFile (builtins.getEnv "FIXTURE_LOCK"));
    getSource = node: builtins.toString (builtins.fetchTree (builtins.removeAttrs node.locked [ "dir" ]));
  in {
    devenv = getSource lock.nodes.devenv + "/src/modules";
    nixpkgs = getSource lock.nodes.nixpkgs;
  }
')
devenv_source=$(jq -er .devenv <<<"$inputs")
nixpkgs_source=$(jq -er .nixpkgs <<<"$inputs")
test -d "$devenv_source" -a -d "$nixpkgs_source"

devenv_project() {
  env -u DEVENV_ROOT -u DEVENV_DOTFILE -u DEVENV_STATE -u DEVENV_PROFILE -u DEVENV_RUNTIME \
    DEVENV_USER_CONFIG=/dev/null DEVENV_NO_AI_AGENT=1 \
    devenv --from "path:$project" --offline "$@"
}
devenv_project print-dev-env --json >"$test_root/print-dev-env.json"
devenv_project eval scripts.check.exec >"$test_root/check.json"

test ! -e "$project/.devenv-enterShell-ran" || {
  echo "host preparation executed the project's enterShell" >&2
  exit 1
}
lock_after=$(sha256sum "$project/devenv.lock" | awk '{print $1}')
[ "$lock_before" = "$lock_after" ] || { echo "host preparation modified the committed lockfile" >&2; exit 1; }

host_root=$(jq -er '.variables.DEVENV_ROOT.value | strings' "$test_root/print-dev-env.json")
host_runtime=$(jq -er '.variables.DEVENV_RUNTIME.value | strings' "$test_root/print-dev-env.json")
profile=$(jq -er '.variables.DEVENV_PROFILE.value | strings | select(startswith("/nix/store/"))' "$test_root/print-dev-env.json")
check=$(jq -er '."scripts.check.exec" | strings | select(length > 0)' "$test_root/check.json")

if jq -e '
  [.variables | to_entries[]
    | select(.value.type == "exported")
    | select(.key | test("(SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL|AUTH|API_KEY|PRIVATE_KEY|COOKIE|SSH_)"; "i"))]
  | length > 0
' "$test_root/print-dev-env.json" >/dev/null; then
  echo "refusing to persist a credential-named exported Devenv variable" >&2
  exit 1
fi

# Persist only exported values plus the generated shellHook and the selected
# project check. Replace host-only roots before the data enters the Nix store.
jq -n --slurpfile env "$test_root/print-dev-env.json" --arg root "$host_root" \
  --arg runtime "$host_runtime" --arg check "$check" '
  def rewrite($s): ($s | split($root) | join("__PROJECT_ROOT__") | split($runtime) | join("__DEVENV_RUNTIME__"));
  ($env[0].variables | with_entries(
    select(.value.type == "exported")
    | select((.key | test("^(HOME|TMPDIR|PWD|OLDPWD|TEMP|TEMPDIR|DEVENV_ROOT|DEVENV_DOTFILE|DEVENV_STATE|DEVENV_RUNTIME|shellHook)$"; "i")) | not)
    | .value.value |= rewrite(.))) as $variables
  | {
      schema_version: 1,
      variables: ($variables + {
        DEVENV_PROFILE: { type: "exported", value: $env[0].variables.DEVENV_PROFILE.value },
        DEVENV_ROOT: { type: "exported", value: "__PROJECT_ROOT__" },
        DEVENV_DOTFILE: { type: "exported", value: "__PROJECT_ROOT__/.devenv" },
        DEVENV_STATE: { type: "exported", value: "__PROJECT_ROOT__/.devenv/state" },
        DEVENV_RUNTIME: { type: "exported", value: "__DEVENV_RUNTIME__" },
        shellHook: { type: "exported", value: rewrite($env[0].variables.shellHook.value) }
      }),
      check: $check
    }
' >"$test_root/projected.json"

if ! jq -e --arg profile "$profile" '
  .schema_version == 1
  and .variables.DEVENV_PROFILE.value == $profile
  and .variables.PROJECT_NATIVE_MARKER.value == "generated-devenv-environment"
  and .variables.PROJECT_NATIVE_IMPORT.value == "generated-devenv-import"
  and (.variables.shellHook.value | contains("$DEVENV_ROOT/.devenv-enterShell-ran"))
  and (.check | contains("make check"))
  and ([.variables[] | select(.type == "exported") | .value | strings | select(test("/home/|/run/user/|/tmp/|/var/tmp/"))] | length == 0)
' "$test_root/projected.json" >/dev/null
then
  jq --arg profile "$profile" '{
    profileMatches: (.variables.DEVENV_PROFILE.value == $profile),
    marker: .variables.PROJECT_NATIVE_MARKER.value,
    imported: .variables.PROJECT_NATIVE_IMPORT.value,
    hookHasGuestMarker: (.variables.shellHook.value | contains("$DEVENV_ROOT/.devenv-enterShell-ran")),
    check: .check,
    hostPaths: [.variables[] | select(.type == "exported") | .value | strings | select(test("/home/|/run/user/|/tmp/|/var/tmp/"))]
  }' "$test_root/projected.json" >&2
  exit 1
fi

profile_root="$test_root/profile-root"
nix-store --add-root "$profile_root" --indirect --realise "$profile" >/dev/null
env_json=$(nix store add --mode flat --name native-devenv-env.json "$test_root/projected.json")
echo "generated Devenv profile: $profile"
echo "projected environment record: $env_json"
echo "host hook marker: absent; tracked lock unchanged: yes"

AGENT_RUNTIME_DEVENV_ENV_JSON="$env_json" AGENT_RUNTIME_DEVENV_PROFILE="$profile" \
  nix build --impure --no-link --print-build-logs \
    .#agent-runtime-devenv-projection-test
