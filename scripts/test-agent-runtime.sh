#!/usr/bin/env bash
# Runs the tests/agent-runtime consumer fixture against this checkout: the
# fixture imports the module through its nixos-config input, nothing copied.
set -euo pipefail
cd "$(dirname "$0")/.."

fixture="git+file://$PWD?dir=tests/agent-runtime"
override=(--override-input nixos-config "git+file://$PWD" --no-write-lock-file)
fail() { printf 'agent-runtime-test: %s\n' "$1" >&2; exit 1; }

# What only the external path proves: both templates reach the consumer through the input, a
# real nixosSystem importing the module evaluates to a toplevel (eval only, no build), and the
# same host with one bad template is refused by NixOS's own assertion path.
nix eval --json "$fixture#agentRuntime.manifestData" "${override[@]}" \
  | jq -e 'keys == ["docs-reviewer", "rust-worker"]' >/dev/null || fail "expected exactly the two fixture templates"
nix eval --raw "$fixture#nixosConfigurations.consumer.config.system.build.toplevel.drvPath" "${override[@]}" >/dev/null \
  || fail "the consumer nixosSystem does not evaluate to a toplevel"
if out=$(nix eval --raw "$fixture#nixosConfigurations.consumer-bad.config.system.build.toplevel.drvPath" "${override[@]}" 2>&1); then
  fail "consumer-bad evaluated to a toplevel"
fi
grep -qF -- "names unknown template" <<<"$out" || { printf '%s\n' "$out" >&2; fail "consumer-bad failed for another reason"; }

# One `nix eval` per negative case: tryEval (check.nix) cannot surface the message, this can.
count=0
while IFS=$'\t' read -r name expect; do
  if out=$(nix eval --json "$fixture#agentRuntimeNegative.$name.manifestData" "${override[@]}" 2>&1); then
    fail "negative case $name evaluated"
  fi
  grep -qF -- "$expect" <<<"$out" || { printf '%s\n' "$out" >&2; fail "negative case $name failed without '$expect'"; }
  count=$((count + 1))
done < <(nix eval --json "$fixture#agentRuntimeCases" "${override[@]}" | jq -r '.[] | [.name, .expect] | @tsv')
[ "$count" -gt 0 ] || fail "no negative cases"
printf 'agent-runtime-test: %d negative cases fail as expected; consumer toplevel ok, consumer-bad refused\n' "$count"
