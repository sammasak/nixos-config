#!/usr/bin/env bash
# agent-runtime-verify trusts only a template manifest that resolves into /nix/store: a copy next to
# the bundle (or a link to one) is refused before anything is read; a store path gets past the check.
set -euo pipefail
cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { printf 'verify-trust-test: %s\n' "$1" >&2; exit 1; }
cat modules/agent-runtime/runtime/lib.sh modules/agent-runtime/runtime/verify.sh >"$work/verify"
mkdir "$work/bundle"
echo '{"kind": "agent-runtime-template", "sources": {}}' >"$work/claude-coder.json"
ln -s "$work/claude-coder.json" "$work/link.json"

for t in "$work/claude-coder.json" "$work/link.json"; do
  rc=0; out=$(bash "$work/verify" --bundle "$work/bundle" --template "$t" 2>&1) || rc=$?
  { [ "$rc" = 2 ] && grep -qF 'does not resolve into /nix/store' <<<"$out"; } || fail "$t was not refused as untrusted (rc $rc): $out"
done

# a store file that is no manifest: past the trust check, refused as malformed instead
store=$(readlink -f "$(command -v jq)")
case $store in /nix/store/*) ;; *) fail "jq is not in /nix/store; cannot exercise the accepted path" ;; esac
rc=0; out=$(bash "$work/verify" --bundle "$work/bundle" --template "$store" 2>&1) || rc=$?
grep -qF 'is not an agent-runtime template manifest' <<<"$out" || fail "a store path did not pass the trust check (rc $rc): $out"
printf 'verify-trust-test: non-store manifests refused, store manifests pass the trust check\n'
