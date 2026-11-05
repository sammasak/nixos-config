#!/usr/bin/env bash
# Runs the tests/agent-runtime consumer fixture against this checkout.
set -euo pipefail
cd "$(dirname "$0")/.."

fixture="git+file://$PWD?dir=tests/agent-runtime"
override=(--override-input nixos-config "git+file://$PWD" --no-write-lock-file)
fail() { printf 'agent-runtime-test: %s\n' "$1" >&2; exit 1; }

# Only the external path proves: input wiring, a real toplevel, and refusal of consumer-bad.
nix eval --json "$fixture#agentRuntime.manifestData" "${override[@]}" \
  | jq -e 'keys == ["docs-reviewer", "rust-worker"]' >/dev/null || fail "expected exactly the two fixture templates"
nix eval --raw "$fixture#nixosConfigurations.consumer.config.system.build.toplevel.drvPath" "${override[@]}" >/dev/null \
  || fail "the consumer nixosSystem does not evaluate to a toplevel"
if out=$(nix eval --raw "$fixture#nixosConfigurations.consumer-bad.config.system.build.toplevel.drvPath" "${override[@]}" 2>&1); then
  fail "consumer-bad evaluated to a toplevel"
fi
{ grep -qF -- "Failed assertions:" <<<"$out" && grep -qF -- "names unknown template" <<<"$out"; } \
  || { printf '%s\n' "$out" >&2; fail "consumer-bad was not refused by the NixOS assertions"; }

# One `nix eval` per negative case (each re-copies the checkout and re-evaluates nixpkgs):
# tryEval (check.nix) cannot surface the message, this can.
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
