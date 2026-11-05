# `nix flake check` half of the eval test: the example templates build their
# manifests (jq-verified shape), every negative case fails to evaluate.
{ pkgs, lib, inputs }:
let
  runtime = import ../../modules/agent-runtime/lib.nix { inherit lib pkgs; };
  args = { inherit (inputs) factum skills; };
  templates = import ./templates.nix args;
  good = runtime.evalManifests { modules = [ templates ]; };
  evaluates =
    c:
    (builtins.tryEval (
      builtins.deepSeq (runtime.evalManifests { modules = [ templates c.module ]; }).manifestData true
    )).success;
  unexpected = map (c: c.name) (builtins.filter evaluates (import ./cases.nix (args // { inherit lib; })));
in
assert lib.assertMsg (unexpected == [ ]) "agent-runtime negative cases evaluated: ${lib.concatStringsSep ", " unexpected}";
pkgs.runCommand "agent-runtime-eval"
  {
    nativeBuildInputs = [ pkgs.jq ];
    manifests = good.manifestDir;
  }
  ''
    set -eu
    for f in "$manifests"/*.json; do
      name=$(basename "$f" .json)
      jq -e --arg n "$name" '
        .schemaVersion == 1 and .kind == "agent-runtime-template" and .template.name == $n
        and (.digests.template | test("^[0-9a-f]{64}$")) and (.digests.lockedSources | test("^[0-9a-f]{64}$"))
        and ([.sources[] | (.locked == null) == (.resolve == "assignment")] | all)
        and ([.sources[] | select(.locked != null) | .locked.rev | test("^[0-9a-f]{40}$")] | all)
        and ([paths(..) | .[] | strings | test("token|secret|password|credential"; "i")] | any | not)
      ' "$f" >/dev/null || { echo "$name: manifest shape"; exit 1; }
      jq -r '.skills[].path' "$f" | while read -r p; do test -f "$p/SKILL.md" || { echo "$name: skill $p"; exit 1; }; done
      jq -r '.packages[].storePath' "$f" | while read -r p; do test -e "$p" || { echo "$name: package $p"; exit 1; }; done
    done
    jq -e '.skills | keys == ["nix-flake-development", "rust-engineering"]' "$manifests/rust-worker.json" >/dev/null
    jq -e '.sources.factum.locked.rev == "${inputs.factum.rev}" and .sources.factum.writable' "$manifests/rust-worker.json" >/dev/null
    jq -e '.sources.factum.locked == null and .sources.factum.ref.type == "tag"' "$manifests/docs-reviewer.json" >/dev/null
    mkdir -p "$out" && cp "$manifests"/*.json "$out"/
  ''
