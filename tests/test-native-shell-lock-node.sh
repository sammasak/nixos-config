#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

fixture_root="$repo_root/tests/fixtures/native-shell-lock-node"
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
project="$test_root/project"
dependency="$test_root/dependency"
mkdir -p "$project" "$dependency"
cp "$fixture_root/dependency/flake.nix" "$dependency/flake.nix"

dep_store_path=$(nix store add-path --name native-shell-no-rev-dependency "$dependency")
nixpkgs_store_path=$(nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.nixpkgs.outPath')
sed \
  -e "s|@NATIVE_SHELL_DEP_PATH@|$dep_store_path|g" \
  -e "s|@NATIVE_SHELL_NIXPKGS_PATH@|$nixpkgs_store_path|g" \
  "$fixture_root/project/flake.nix.in" > "$project/flake.nix"

nix flake lock --impure "$project" >/dev/null
dep_node=$(jq -er '.nodes.root.inputs.dep' "$project/flake.lock")
expected_locked=$(jq -cer --arg node "$dep_node" '.nodes[$node].locked' "$project/flake.lock")
jq -e --arg node "$dep_node" '
  .nodes[$node].locked.type == "path" and
  (.nodes[$node].locked.narHash | type == "string") and
  (.nodes[$node].locked | has("rev") | not)
' "$project/flake.lock" >/dev/null

info_path=$(NATIVE_SHELL_TEST_SOURCE="$project" nix build \
  --impure --no-link --print-out-paths --file tests/native-shell-lock-node-eval.nix)
jq -e --argjson expected "$expected_locked" '
  .shell == "devShells.x86_64-linux.default" and
  .drvPath != "" and
  .lock.dep == $expected
' "$info_path" >/dev/null
printf 'PASS: resolver built a shell and preserved exact no-rev lock provenance\n'

jq --arg node "$dep_node" 'del(.nodes[$node].locked.narHash)' \
  "$project/flake.lock" > "$test_root/flake.lock.without-nar-hash"
cp "$test_root/flake.lock.without-nar-hash" "$project/flake.lock"
if NATIVE_SHELL_TEST_SOURCE="$project" nix build \
  --impure --no-link --print-out-paths --file tests/native-shell-lock-node-eval.nix \
  > "$test_root/unpinned.stdout" 2> "$test_root/unpinned.stderr"; then
  echo "FAIL: resolver accepted a lock node without narHash" >&2
  exit 1
fi
grep -Fq 'lock node dep has no narHash; refusing an unpinned input' "$test_root/unpinned.stderr"
printf 'PASS: resolver rejects a no-rev lock node without narHash\n'
