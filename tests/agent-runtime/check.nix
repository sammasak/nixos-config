# `nix flake check` half of the eval test (scripts/test-agent-runtime.sh is
# the other): the example manifests pass the shape checks (realizing their
# package closures, substituted not built) and every negative case fails.
{
  pkgs,
  lib,
  runtime,
  templates,
  cases,
  manifests,
  factumRev,
}:
let
  evaluates =
    c:
    (builtins.tryEval (
      builtins.deepSeq (runtime.evalManifests { modules = [ templates c.module ]; }).manifestData true
    )).success;
  unexpected = map (c: c.name) (builtins.filter evaluates cases);
in
assert lib.assertMsg (unexpected == [ ]) "agent-runtime negative cases evaluated: ${lib.concatStringsSep ", " unexpected}";
pkgs.runCommand "agent-runtime-eval"
  {
    nativeBuildInputs = [ pkgs.jq ];
    inherit manifests factumRev;
  }
  ''
    set -euo pipefail
    fail() { printf 'agent-runtime-eval: %s\n' "$2" >&2; jq . "$1" >&2; exit 1; }
    for f in "$manifests"/*.json; do
      name=$(basename "$f" .json)
      jq -e --arg n "$name" '
        .schemaVersion == 1 and .kind == "agent-runtime-template" and .template.name == $n
        and (.digests.template | test("^[0-9a-f]{64}$")) and (.digests.lockedSources | test("^[0-9a-f]{64}$"))
        and (.sources | type == "object" and length > 0)
        and (.skills.names | type == "object" and length > 0) and (.packages | type == "array" and length > 0)
      ' "$f" >/dev/null || fail "$f" "$name: header, digests, skills or packages"
      # a source is unlocked exactly when it resolves per assignment
      jq -e '
        ([.sources[] | (.locked == null) == (.resolve == "assignment")] | all)
        and ([.sources[] | select(.locked != null) | .locked.rev | test("^[0-9a-f]{40}$")] | all)
      ' "$f" >/dev/null || fail "$f" "$name: source locking"
      jq -e '
        ([.. | objects | keys[] | test("token|secret|password|credential|apikey"; "i")] | any | not)
        and ([.. | strings | test("gh[opsur]_|github_pat_|sk-ant-|AKIA[0-9A-Z]{16}|-----BEGIN")] | any | not)
      ' "$f" >/dev/null || fail "$f" "$name: secret-like field or value"
      while read -r p; do test -f "$p/SKILL.md" || fail "$f" "$name: skill $p"; done < <(jq -r '.skills.names[].path' "$f")
      while read -r p; do test -e "$p" || fail "$f" "$name: package $p"; done < <(jq -r '.packages[].storePath' "$f")
    done
    rw="$manifests/rust-worker.json"
    dr="$manifests/docs-reviewer.json"
    jq -e '.skills.names | keys == ["nix-flake-development", "rust-engineering"]' "$rw" >/dev/null || fail "$rw" "rust-worker: skills"
    jq -e '.packages | length == 4' "$rw" >/dev/null || fail "$rw" "rust-worker: packages (mirrors templates.nix)"
    jq -e '.policies | .network == { egress: "allowlist", allow: ["crates.io", "github.com", "static.crates.io"] }
      and .capabilities == ["github-comment", "github-read"] and .resources.memoryMiB == 3072' "$rw" >/dev/null \
      || fail "$rw" "rust-worker: policies"
    jq -e '.policies.network == { egress: "none", allow: [] }' "$dr" >/dev/null \
      || fail "$dr" "docs-reviewer: no egress"
    jq -e --arg rev "$factumRev" '.sources.factum | .locked.rev == $rev and .writable' "$rw" >/dev/null || fail "$rw" "rust-worker: locked branch"
    jq -e '.sources["factum-pinned"] | .locked.rev == .ref.value and (.locked.storePath | startswith("/nix/store/"))' "$rw" >/dev/null || fail "$rw" "rust-worker: commit"
    jq -e '.sources["factum-release"] | .locked == null and .ref.type == "tag"' "$rw" >/dev/null || fail "$rw" "rust-worker: tag"
    jq -e '[.filesystem.mounts[] | .writable] == [false, true]' "$rw" >/dev/null || fail "$rw" "rust-worker: mounts"
    touch "$out"
  ''
