# Runtime adapter check (#136): assign, materialize, export and reclaim run
# against fixture trees and a fake `nix` that answers `flake prefetch` from a
# table, so the sandbox needs no network. One locked branch, one pinned commit
# and one assignment-resolved tag (advanced between runs); two instances of one
# writable source; the credential, store and path failure classes; and the
# export-before-reclaim rule.
{
  pkgs,
  lib,
  manifests,
}:
let
  tree =
    name: body:
    pkgs.runCommand "fixture-${name}" { } ''
      mkdir -p "$out/src"
      cd "$out"
      ${body}
    '';
  srcA = tree "a" ''
    printf 'a1\n' > README
    printf 'fn a() {}\n' > src/lib.rs
    ln -s README link
  '';
  srcB = tree "b" ''
    printf 'a2\n' > README
    printf 'fn b() {}\n' > src/lib.rs
  '';
  escape = tree "escape" ''
    printf 'x\n' > README
    ln -s /etc/passwd evil
  '';
  nix = "${pkgs.nix}/bin/nix";
  fakeNix = pkgs.writeShellScriptBin "nix" ''
    set -euo pipefail
    case " $* " in
      *" flake prefetch "*)
        url=''${!#}
        printf '%s\n' "''${NIX_CONFIG:-}" >"$FAKE_NIX_LOG"
        if [ "''${FAKE_NIX_FAIL:-}" = 1 ]; then
          echo "error: unable to download '$url': HTTP 401 (config: ''${NIX_CONFIG:-none})" >&2
          exit 1
        fi
        sp=$(${pkgs.gawk}/bin/awk -F '\t' -v u="$url" '$1 == u { print $2 }' "$FAKE_NIX_TABLE")
        [ -n "$sp" ] || { echo "error: $url is not in the prefetch table" >&2; exit 1; }
        ${pkgs.jq}/bin/jq -n --arg h "$(${nix} --extra-experimental-features nix-command hash path "$sp")" --arg p "$sp" \
          '{hash: $h, storePath: $p, locked: {}}'
        ;;
      *) exec ${nix} "$@" ;;
    esac
  '';
  tools = import ../../modules/agent-runtime/runtime.nix {
    inherit pkgs;
    nix = fakeNix;
  };
in
pkgs.runCommand "agent-runtime-runtime"
  {
    nativeBuildInputs = [
      pkgs.jq
      pkgs.nix
      pkgs.diffutils
    ];
    inherit
      manifests
      srcA
      srcB
      escape
      ;
    assign = lib.getExe tools.assign;
    materialize = lib.getExe tools.materialize;
    export_ = lib.getExe tools.export;
    reclaim = lib.getExe tools.reclaim;
  }
  ''
    set -euo pipefail
    fail() { printf 'agent-runtime-runtime: %s\n' "$1" >&2; exit 1; }
    expect() { [ "$2" = "$3" ] || fail "$1: expected '$2', got '$3'"; echo "ok   - $1"; }
    class() { tail -n 1 "$1" | jq -r '.error.class' 2>/dev/null || echo "(no json error)"; }
    export HOME=$TMPDIR FAKE_NIX_LOG=$TMPDIR/nix.log FAKE_NIX_TABLE=$TMPDIR/table
    hashA=$(nix --extra-experimental-features nix-command hash path "$srcA")
    hashE=$(nix --extra-experimental-features nix-command hash path "$escape")
    S1=1111111111111111111111111111111111111111
    S2=2222222222222222222222222222222222222222
    REVA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    REVP=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    printf 'github:sammasak/factum/%s\t%s\ngithub:sammasak/factum/%s\t%s\n' "$S1" "$srcA" "$S2" "$srcB" >"$FAKE_NIX_TABLE"
    jq --arg a "$srcA" --arg h "$hashA" --arg ra "$REVA" --arg rp "$REVP" '
      .sources.factum.locked = {rev: $ra, narHash: $h, storePath: $a}
      | .sources["factum-pinned"].locked = {rev: $rp, narHash: $h, storePath: $a}' "$manifests/rust-worker.json" >T.json
    jq -e '.sources["factum-release"].resolve == "assignment" and .sources.factum.writable == true
           and .sources["factum-pinned"].writable == false' T.json >/dev/null || fail "fixture template shape"
    plan() {
      jq -n --arg ref "$1" --arg sha "$2" '{schema_version: 1, source: {url: "https://github.com/sammasak/factum",
        repo: "sammasak/factum", ref: $ref, sha: $sha, subproject: "."}}'
    }
    plan v0.2.0 "$S1" >plan1.json
    plan v0.2.0 "$S2" >plan2.json

    rc=0; $assign --template T.json --run r1 --out o1 2>err || rc=$?
    expect "assignment source without a plan: exit 3, class github" "3 github" "$rc $(class err)"
    $assign --template T.json --run r1 --out o1 --plan plan1.json
    expect "run manifest: the tag is resolved from the plan and prefetched" "agent-runtime-run $S1 $hashA $srcA plan" \
      "$(jq -r '"\(.kind) \(.sources["factum-release"].resolved | "\(.rev) \(.narHash) \(.storePath) \(.by)")"' o1/run.json)"
    expect "locked sources copy their lock" "lock $REVA lock $REVP" \
      "$(jq -r '"\(.sources.factum.resolved.by) \(.sources.factum.resolved.rev) \(.sources["factum-pinned"].resolved.by) \(.sources["factum-pinned"].resolved.rev)"' o1/run.json)"
    expect "run digest, template digests, no lock field survives" "true" \
      "$(jq '(.digests.run | test("^[0-9a-f]{64}$")) and (.template.digests.template | test("^[0-9a-f]{64}$")) and ([.sources[] | has("locked")] | any | not)' o1/run.json)"
    rc=0; $assign --template T.json --run r1 --out o1 --plan plan1.json 2>err || rc=$?
    expect "a run is assigned once" "1 state" "$rc $(class err)"
    cp o1/run.json run1.before
    $assign --template T.json --run r2 --out o2 --plan plan2.json
    expect "the tag advanced between assignments: run 2 takes the new commit" "$S2 $srcB" \
      "$(jq -r '.sources["factum-release"].resolved | "\(.rev) \(.storePath)"' o2/run.json)"
    cmp -s run1.before o1/run.json || fail "run 1 changed after run 2 was assigned"
    echo "ok   - run 1 stays on its captured commit"

    jq '.sources["factum-release"].access = "private"' T.json >Tp.json
    : >"$FAKE_NIX_LOG"
    rc=0; env -u GH_TOKEN $assign --template Tp.json --run r3 --out o3 --plan plan1.json 2>err || rc=$?
    expect "private source without GH_TOKEN: exit 5, class credential, nothing fetched" "5 credential 0" "$rc $(class err) $(stat -c %s "$FAKE_NIX_LOG")"
    GH_TOKEN=ghp_testsecret4711 $assign --template Tp.json --run r3 --out o3 --plan plan1.json >out 2>err
    expect "private source: the token reaches nix as an access-token only" "access-tokens = github.com=ghp_testsecret4711" "$(cat "$FAKE_NIX_LOG")"
    expect "the token is in no manifest or output" "0" "$(cat o3/run.json out err | grep -c ghp_testsecret4711 || true)"
    rc=0; FAKE_NIX_FAIL=1 GH_TOKEN=ghp_testsecret4711 $assign --template Tp.json --run r4 --out o4 --plan plan1.json 2>err || rc=$?
    expect "prefetch failure: exit 4, class nix, token redacted" "4 nix true false" \
      "$rc $(class err) $(grep -q '<redacted>' err && echo true || echo false) $(grep -q ghp_testsecret4711 err && echo true || echo false)"
    expect "a failed assignment writes no run manifest" "false" "$([ -e o4/run.json ] && echo true || echo false)"

    $materialize --run o1/run.json --root i1
    $materialize --run o1/run.json --root i2
    expect "binds: a private copy for the writable source, store paths for the rest" \
      "$(printf 'rw\t%s/i1/workspace/factum\t/workspace/factum\nro\t%s\t/workspace/factum-pinned\nro\t%s\t/workspace/factum-release' "$PWD" "$srcA" "$srcA")" \
      "$(cat i1/binds)"
    diff -r "$srcA" i1/workspace/factum >/dev/null || fail "instance 1 differs from the pinned tree"
    diff -r i1/workspace/factum i2/workspace/factum >/dev/null || fail "the two instances differ"
    echo "ok   - two instances: identical initial content, equal to the pinned tree"
    echo change >>i1/workspace/factum/README
    expect "a write in one instance is invisible in the other" "a1" "$(cat i2/workspace/factum/README)"
    expect "the writable source is export-pending" "factum" "$(cat i1/export-pending)"
    expect "materialized.json: the instance record" "r1 rw $REVA $hashA ro" \
      "$(jq -r '"\(.run.id) \(.sources.factum.mode) \(.sources.factum.rev) \(.sources.factum.narHash) \(.sources["factum-pinned"].mode)"' i1/materialized.json)"
    rc=0; $materialize --run o1/run.json --root i1 2>err || rc=$?
    expect "materializing twice is refused" "1 state" "$rc $(class err)"

    jq '.sources.factum.resolved.narHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="' o1/run.json >bad-hash.json
    rc=0; $materialize --run bad-hash.json --root i3 2>err || rc=$?
    expect "NAR hash mismatch: exit 4, class store, nothing left behind" "4 store false" "$rc $(class err) $([ -e i3/workspace ] && echo true || echo false)"
    jq '.sources.factum.resolved.storePath = "/nix/store/00000000000000000000000000000000-missing"' o1/run.json >missing.json
    rc=0; $materialize --run missing.json --root i4 2>err || rc=$?
    expect "missing store path: exit 4, class store" "4 store" "$rc $(class err)"
    jq '.sources.factum.path = "/workspace/../etc"' o1/run.json >traversal.json
    rc=0; $materialize --run traversal.json --root i5 2>err || rc=$?
    expect "path traversal: exit 6, class path" "6 path" "$rc $(class err)"
    jq --arg e "$escape" --arg h "$hashE" '.sources.factum.resolved += {storePath: $e, narHash: $h}' o1/run.json >escape.json
    rc=0; $materialize --run escape.json --root i6 2>err || rc=$?
    expect "symlink escape: exit 6, class source" "6 source" "$rc $(class err)"

    rc=0; $reclaim --root i1 2>err || rc=$?
    expect "reclaim refuses while export is pending" "1 state true" "$rc $(class err) $([ -d i1/workspace/factum ] && echo true || echo false)"
    $export_ --root i1 --out x1
    expect "export: the patch carries the change" "+change" "$(grep '^+change' x1/factum.patch)"
    expect "export: changed paths, base and patch digest" "[\"README\"] $REVA true" \
      "$(jq -r '"\(.changedPaths | tojson) \(.base.rev) \(.patchSha256 | test("^[0-9a-f]{64}$"))"' x1/factum.json)"
    expect "export.json summary; the marker is cleared" "agent-runtime-export 1 false" \
      "$(jq -r '"\(.kind) \(.sources.factum.changed)"' x1/export.json) $([ -e i1/export-pending ] && echo true || echo false)"
    $reclaim --root i1
    expect "reclaim after export removes the workspace" "false true" "$([ -e i1/workspace ] && echo true || echo false) $([ -f i1/reclaimed ] && echo true || echo false)"
    $export_ --root i2 --out x2
    expect "an untouched instance exports an empty patch" "0 0" "$(jq -r '.sources.factum.changed' x2/export.json) $(stat -c %s x2/factum.patch)"
    touch "$out"
  ''
