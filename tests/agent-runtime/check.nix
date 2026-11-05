# `nix flake check` half of the eval test: the example manifests pass a jq
# shape check (realizing their package closures, substituted not built) and
# every negative case fails to evaluate; the message match is the script's job.
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
    inherit manifests;
  }
  ''
    set -euo pipefail
    fail() { echo "agent-runtime-eval: $1" >&2; exit 1; }
    for f in "$manifests"/*.json; do
      name=$(basename "$f" .json)
      jq -e --arg n "$name" '
        .schemaVersion == 1 and .kind == "agent-runtime-template" and .template.name == $n
        and (.digests.template | test("^[0-9a-f]{64}$")) and (.digests.lockedSources | test("^[0-9a-f]{64}$"))
        and ([.sources[] | (.locked == null) == (.resolve == "assignment")] | all)
        and ([.sources[] | select(.locked != null) | .locked.rev | test("^[0-9a-f]{40}$")] | all)
        and ([.. | objects | keys[] | test("^(token|secret|password|credential)s?$"; "i")] | any | not)
        and ([.. | strings | test("ghp_|github_pat_|-----BEGIN")] | any | not)
      ' "$f" >/dev/null || { jq . "$f" >&2; fail "$name: manifest shape"; }
      while read -r p; do test -f "$p/SKILL.md" || fail "$name: skill $p"; done < <(jq -r '.skills[].path' "$f")
      while read -r p; do test -e "$p" || fail "$name: package $p"; done < <(jq -r '.packages[].storePath' "$f")
    done
    rw="$manifests/rust-worker.json"
    jq -e '.skills | keys == ["nix-flake-development", "rust-engineering"]' "$rw" >/dev/null || fail "rust-worker: skills"
    jq -e '.sources.factum.locked.rev == "${factumRev}" and .sources.factum.writable' "$rw" >/dev/null || fail "rust-worker: locked branch"
    jq -e '.sources["factum-pinned"] | .locked.rev == .ref.value and .locked.storePath != null' "$rw" >/dev/null || fail "rust-worker: commit"
    jq -e '.sources["factum-release"] | .locked == null and .ref.type == "tag"' "$rw" >/dev/null || fail "rust-worker: tag"
    mkdir -p "$out" && cp "$manifests"/*.json "$out"/
  ''
