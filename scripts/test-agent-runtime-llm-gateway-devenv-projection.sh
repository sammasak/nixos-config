#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"
expected_rev=4a17b9241d8ad3702777ea85001597910e169e5b
work=$(mktemp -d /tmp/agent-runtime-llm-gateway.XXXXXX)
trap 'rm -rf "$work"' EXIT
project="$work/project"
mkdir -p "$project"

source_path=$(EXPECTED_REV="$expected_rev" nix eval --impure --raw --expr '
  let
    lock = builtins.fromJSON (builtins.readFile ./flake.lock);
    node = lock.nodes."llm-gateway";
    source = builtins.fetchTree (builtins.removeAttrs node.locked [ "dir" ]);
  in if node.locked.rev == builtins.getEnv "EXPECTED_REV"
     then toString source
     else throw "llm-gateway flake.lock revision differs from expected pin"
')
test -d "$source_path"
cp -R "$source_path"/. "$project"/
chmod -R u+w "$project"
lock_before=$(sha256sum "$project/devenv.lock" | awk '{print $1}')

devenv_project() {
  (
    cd "$project"
    env -u DEVENV_ROOT -u DEVENV_DOTFILE -u DEVENV_STATE -u DEVENV_PROFILE -u DEVENV_RUNTIME \
      DEVENV_USER_CONFIG=/dev/null DEVENV_NO_AI_AGENT=1 devenv --offline "$@"
  )
}
devenv_project print-dev-env --json >"$work/print-dev-env.json"
devenv_project eval tasks >"$work/tasks.json"
test ! -e "$project/.devenv-enterShell-ran" || {
  echo "host preparation executed llm-gateway's enterShell" >&2
  exit 1
}
lock_after=$(sha256sum "$project/devenv.lock" | awk '{print $1}')
test "$lock_before" = "$lock_after" || {
  echo "host preparation modified llm-gateway's committed devenv.lock" >&2
  exit 1
}

profile=$(jq -er '.variables.DEVENV_PROFILE.value | strings | select(startswith("/nix/store/"))' "$work/print-dev-env.json")
task=$(jq -er '.tasks["rust:test"].command | strings | select(startswith("/nix/store/"))' "$work/tasks.json")
test -x "$task"
if jq -e '[.variables | to_entries[] | select(.value.type == "exported") | select(.key | test("(SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL|AUTH|API_KEY|PRIVATE_KEY|COOKIE|SSH_)"; "i"))] | length > 0' "$work/print-dev-env.json" >/dev/null; then
  echo "refusing to persist credential-named exported Devenv variables" >&2
  exit 1
fi

host_root=$(jq -er '.variables.DEVENV_ROOT.value | strings' "$work/print-dev-env.json")
host_runtime=$(jq -er '.variables.DEVENV_RUNTIME.value | strings' "$work/print-dev-env.json")
jq -n --slurpfile env "$work/print-dev-env.json" --arg root "$host_root" \
  --arg runtime "$host_runtime" --arg task "$task" '
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
      check: $task
    }
' >"$work/projected.json"

jq -e --arg profile "$profile" '
  .schema_version == 1
  and .variables.DEVENV_PROFILE.value == $profile
  and (.check | startswith("/nix/store/"))
  and ([.variables[] | select(.type == "exported") | .value | strings | select(test("/home/|/run/user/|/tmp/|/var/tmp/"))] | length == 0)
' "$work/projected.json" >/dev/null || {
  echo "projected environment contains host-local paths or invalid generated values" >&2
  exit 1
}

profile_root="$work/profile-root"
nix-store --add-root "$profile_root" --indirect --realise "$profile" >/dev/null
env_json=$(nix store add --mode flat --name llm-gateway-devenv-env.json "$work/projected.json")
echo "llm-gateway revision: $expected_rev"
echo "Devenv profile: $profile"
echo "selected task: $task"
echo "committed devenv.lock unchanged; host enterShell absent"

flock -w 900 /tmp/acer-swift-heavy-work.lock \
  env AGENT_RUNTIME_LLM_DEVENV_ENV_JSON="$env_json" \
      AGENT_RUNTIME_LLM_DEVENV_PROFILE="$profile" \
      AGENT_RUNTIME_LLM_DEVENV_TASK="$task" \
  nix build --impure --no-link --print-build-logs \
    "$repo_root#agent-runtime-llm-gateway-devenv-projection-test"
