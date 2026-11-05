#!/usr/bin/env bash
# External-consumer eval of the agent-runtime module: the fixture flake under
# tests/agent-runtime imports this repo as an input (nothing copied) and must
# evaluate two templates' manifests, a real nixosSystem importing the module,
# and fail every negative case with its expected message.
set -euo pipefail
cd "$(dirname "$0")/.."

fixture="git+file://$PWD?dir=tests/agent-runtime"
override=(--override-input nixos-config "git+file://$PWD" --no-write-lock-file)
fail() { printf 'agent-runtime-test: %s\n' "$1" >&2; exit 1; }

manifests=$(nix eval --json "$fixture#agentRuntime.manifestData" "${override[@]}")
jq -e 'keys == ["docs-reviewer", "rust-worker"]' <<<"$manifests" >/dev/null || fail "expected exactly the two fixture templates"
jq -e '
  [.[] | .schemaVersion == 1 and .kind == "agent-runtime-template"
       and (.digests.template | test("^[0-9a-f]{64}$"))
       and ([.sources[] | (.locked == null) == (.resolve == "assignment")] | all)
       and ([paths(..) | .[] | strings | test("token|secret|password|credential"; "i")] | any | not)
  ] | all' <<<"$manifests" >/dev/null || fail "manifest shape"
jq -e '.["rust-worker"] | .sources.factum.locked.rev | test("^[0-9a-f]{40}$")' <<<"$manifests" >/dev/null || fail "rust-worker branch is not locked to a revision"

dir=$(nix eval --raw "$fixture#nixosConfigurations.consumer.config.sam.agentRuntime.manifestDir" "${override[@]}") \
  || fail "a nixosSystem importing the module does not evaluate"
case $dir in /nix/store/*-agent-runtime-manifests) ;; *) fail "unexpected manifestDir $dir" ;; esac

cases=$(nix eval --json "$fixture#agentRuntimeCases" "${override[@]}")
count=$(jq length <<<"$cases")
[ "$count" -ge 10 ] || fail "only $count negative cases"
for i in $(seq 0 $((count - 1))); do
  name=$(jq -r ".[$i].name" <<<"$cases")
  expect=$(jq -r ".[$i].expect" <<<"$cases")
  if out=$(nix eval --json "$fixture#agentRuntimeNegative.$name.manifestData" "${override[@]}" 2>&1); then
    fail "negative case $name evaluated"
  fi
  grep -qF -- "$expect" <<<"$out" || { printf '%s\n' "$out" >&2; fail "negative case $name failed without '$expect'"; }
  echo "agent-runtime-test: $name fails as expected"
done
echo "agent-runtime-test: $count negative cases, 2 templates, consumer nixosSystem: ok"
