# Runtime adapter check against fixture trees; a fake `nix` answers `flake
# prefetch` and `build --out-link` from a table, so the sandbox needs no network.
{
  pkgs,
  lib,
  runtime,
  shipped,
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
    printf '\000\001' > bin.dat
    printf '#!/bin/sh\n' > script.sh
    chmod 755 script.sh
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
  realNix = lib.getExe pkgs.nix;
  fakeNix = pkgs.writeShellApplication {
    name = "nix";
    runtimeInputs = [
      pkgs.gawk
      pkgs.jq
    ];
    text = ''
      case " $* " in
        *" flake prefetch "*)
          case " $* " in *" --json "*) ;; *) echo "error: fake nix: --json required" >&2; exit 1 ;; esac
          url=''${!#}
          printf '%s\n' "''${NIX_CONFIG:-}" >>"$FAKE_NIX_LOG"
          if [ -n "''${FAKE_NIX_FAIL:-}" ] && [[ $url == *"$FAKE_NIX_FAIL"* ]]; then
            echo "error: unable to download '$url': HTTP 401 (config: ''${NIX_CONFIG:-none})" >&2
            exit 1
          fi
          sp=$(awk -F '\t' -v u="$url" '$1 == u { print $2 }' "$FAKE_NIX_TABLE")
          [ -n "$sp" ] || { echo "error: $url is not in the prefetch table" >&2; exit 1; }
          jq -n --arg h "$(${realNix} --extra-experimental-features nix-command hash path "$sp")" --arg p "$sp" \
            '{hash: $h, storePath: $p, locked: {}}'
          ;;
        *" build --out-link "*)
          link=''${*: -2:1}
          target=''${!#}
          [ -e "$target" ] || { echo "error: path '$target' is not valid" >&2; exit 1; }
          ln -sfn "$target" "$link"
          ;;
        *) exec ${realNix} "$@" ;;
      esac
    '';
  };
  tools = import ../../modules/agent-runtime/runtime.nix {
    inherit lib pkgs;
    nix = fakeNix;
  };
  placeholder = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  writableRev = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  pinnedRev = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
  lockOf = rev: path: {
    inherit rev;
    narHash = placeholder;
    outPath = "${path}";
  };
  # the NAR hashes are only known once the fixtures are built; the check fills them in
  template = {
    sam.agentRuntime.templates.fixture = {
      role = {
        name = "fixture";
        harness = "claude-code";
      };
      repositories = {
        factum = {
          github = "sammasak/factum";
          ref = {
            type = "branch";
            value = "main";
          };
          lock = lockOf (lib.substring 0 40 writableRev) srcA;
          path = "/workspace/factum";
          writable = true;
        };
        factum-pinned = {
          github = "sammasak/factum";
          ref = {
            type = "commit";
            value = lib.substring 0 40 pinnedRev;
          };
          lock = lockOf (lib.substring 0 40 pinnedRev) srcB;
          path = "/workspace/factum-pinned";
        };
        factum-dev = {
          github = "sammasak/factum";
          ref = {
            type = "branch";
            value = "dev";
          };
          resolve = "assignment";
          path = "/workspace/factum-dev";
        };
        factum-release = {
          github = "sammasak/factum";
          ref = {
            type = "tag";
            value = "v0.2.0";
          };
          resolve = "assignment";
          path = "/workspace/factum-release";
        };
      };
      skillsSource = lockOf (lib.substring 0 40 pinnedRev) srcB;
      filesystem = {
        home.sizeMiB = 64;
        tmp.sizeMiB = 64;
        cache.sizeMiB = 64;
        output.sizeMiB = 64;
      };
      resources = {
        cpus = 1;
        memoryMiB = 512;
        timeoutMinutes = 10;
      };
    };
  };
  manifests = (runtime.evalManifests { modules = [ template ]; }).manifestDir;
in
pkgs.runCommand "agent-runtime-runtime"
  {
    nativeBuildInputs = [
      pkgs.git
      pkgs.jq
      pkgs.nix
    ];
    inherit
      manifests
      srcA
      srcB
      escape
      ;
    assignTool = lib.getExe tools.assign;
    materializeTool = lib.getExe tools.materialize;
    exportTool = lib.getExe tools.export;
    reclaimTool = lib.getExe tools.reclaim;
    shippedReclaim = lib.getExe shipped.reclaim;
  }
  ''
    set -euo pipefail
    fail() { printf 'agent-runtime-runtime: %s\n' "$1" >&2; exit 1; }
    expect() { [ "$2" = "$3" ] || fail "$1: expected '$2', got '$3'"; echo "ok   - $1"; }
    class() { tail -n 1 "$1" | jq -r '.error.class' 2>/dev/null || echo "(no json error)"; }
    exists() { [ -e "$1" ] && echo true || echo false; }
    has() { grep -q -- "$2" "$1" && echo true || echo false; }
    # the tools see nothing but their own runtime inputs
    assign() { env PATH=/var/empty "$assignTool" "$@"; }
    materialize() { env PATH=/var/empty "$materializeTool" "$@"; }
    export_() { env PATH=/var/empty "$exportTool" "$@"; }
    reclaim() { env PATH=/var/empty "$reclaimTool" "$@"; }
    nar() { nix --extra-experimental-features nix-command hash path "$1"; }

    export HOME=$TMPDIR/home FAKE_NIX_LOG=$TMPDIR/nix.log FAKE_NIX_TABLE=$TMPDIR/table
    mkdir -p "$HOME"
    hashA=$(nar "$srcA"); hashB=$(nar "$srcB"); hashE=$(nar "$escape")
    WRITABLE_REV=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    PINNED_REV=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    TAG_SHA_1=1111111111111111111111111111111111111111
    TAG_SHA_2=2222222222222222222222222222222222222222
    DEV_SHA_1=3333333333333333333333333333333333333333
    DEV_SHA_2=4444444444444444444444444444444444444444
    printf 'github:sammasak/factum/%s\t%s\n' "$TAG_SHA_1" "$srcA" "$TAG_SHA_2" "$srcB" "$DEV_SHA_1" "$srcA" "$DEV_SHA_2" "$srcB" >"$FAKE_NIX_TABLE"
    jq --arg a "$hashA" --arg b "$hashB" '.sources.factum.locked.narHash = $a | .sources["factum-pinned"].locked.narHash = $b' \
      "$manifests/fixture.json" >template.json
    jq '.sources["factum-release"].access = "private"' template.json >template-private.json
    plan() {
      jq -n --arg ref "$1" --arg sha "$2" --arg sub "''${3:-.}" '{schema_version: 1, source: {url: "https://github.com/sammasak/factum",
        repo: "sammasak/factum", ref: $ref, sha: $sha, subproject: $sub}}'
    }
    plan v0.2.0 "$TAG_SHA_1" >plan-tag1.json
    plan v0.2.0 "$TAG_SHA_2" >plan-tag2.json
    plan dev "$DEV_SHA_1" >plan-dev1.json
    plan dev "$DEV_SHA_2" >plan-dev2.json
    plan v0.1.0 "$TAG_SHA_1" >plan-wrong-ref.json
    plan v0.2.0 zz >plan-bad-sha.json
    plan v0.2.0 "$TAG_SHA_1" src >plan-subproject.json

    rc=0; assign 2>err || rc=$?
    expect "no arguments: exit 2, class usage as a JSON line" "2 usage" "$rc $(class err)"
    rc=0; assign --template template.json --run >/dev/null 2>err || rc=$?
    expect "a flag without its value: exit 2, class usage" "2 usage" "$rc $(class err)"
    rc=0; assign --template template.json --run r1 --out o1 2>err || rc=$?
    expect "assignment sources without plans: exit 3, class plan" "3 plan" "$rc $(class err)"
    rc=0; assign --template template.json --run r1 --out o1 --plan plan-tag1.json 2>err || rc=$?
    expect "one plan missing (the branch): exit 3, class plan" "3 plan" "$rc $(class err)"
    rc=0; assign --template template.json --run r1 --out o1 --plan plan-wrong-ref.json --plan plan-dev1.json 2>err || rc=$?
    expect "a plan for the right repo but another ref does not match" "3 plan" "$rc $(class err)"
    rc=0; assign --template template.json --run r1 --out o1 --plan plan-bad-sha.json --plan plan-dev1.json 2>err || rc=$?
    expect "a malformed plan (sha not 40 hex) is refused" "3 plan" "$rc $(class err)"
    rc=0; assign --template template.json --run r1 --out o1 --plan plan-subproject.json --plan plan-dev1.json 2>err || rc=$?
    expect "a subproject plan is refused: the adapter materializes whole repositories" "3 plan" "$rc $(class err)"
    expect "nothing was published by the refused assignments" "false" "$(exists o1/run.json)"

    : >"$FAKE_NIX_LOG"
    assign --template template.json --run r1 --out o1 --plan plan-tag1.json --plan plan-dev1.json
    expect "run.json: every source keeps repo, requested ref, path, mode, and how it was resolved" \
      "factum:sammasak/factum:branch:main:/workspace/factum:true:lock factum-dev:sammasak/factum:branch:dev:/workspace/factum-dev:false:plan factum-pinned:sammasak/factum:commit:$PINNED_REV:/workspace/factum-pinned:false:lock factum-release:sammasak/factum:tag:v0.2.0:/workspace/factum-release:false:plan" \
      "$(jq -r '.sources | to_entries | map("\(.key):\(.value.github):\(.value.ref.type):\(.value.ref.value):\(.value.path):\(.value.writable):\(.value.resolved.by)") | join(" ")' o1/run.json)"
    expect "run.json: resolved commits and store paths per source" \
      "$WRITABLE_REV $hashA $srcA | $DEV_SHA_1 $hashA $srcA | $PINNED_REV $hashB $srcB | $TAG_SHA_1 $hashA $srcA" \
      "$(jq -r '[.sources[] | .resolved | "\(.rev) \(.narHash) \(.storePath)"] | join(" | ")' o1/run.json)"
    expect "run.json: kind, template digests, no lock field survives" "agent-runtime-run true false" \
      "$(jq -r '"\(.kind) \(.template.digests.template | test("^[0-9a-f]{64}$")) \([.sources[] | has("locked")] | any)"' o1/run.json)"
    expect "digests.run is the sha256 of the canonical run id, template digests, workspace and sources" \
      "$(jq -cS '{run: {id: .run.id}, template, workspace, sources}' o1/run.json | sha256sum | cut -d' ' -f1)" "$(jq -r .digests.run o1/run.json)"
    expect "every source is GC-rooted under the run directory" "$srcA $srcA $srcB $srcA" \
      "$(readlink o1/gcroots/factum) $(readlink o1/gcroots/factum-dev) $(readlink o1/gcroots/factum-pinned) $(readlink o1/gcroots/factum-release)"
    expect "public sources are prefetched without a token" "2 0" "$(wc -l <"$FAKE_NIX_LOG") $(grep -c access-tokens "$FAKE_NIX_LOG" || true)"
    rc=0; assign --template template.json --run r1 --out o1 --plan plan-tag1.json --plan plan-dev1.json 2>err || rc=$?
    expect "a run is assigned once" "1 state" "$rc $(class err)"
    cp o1/run.json run1.before
    assign --template template.json --run r2 --out o2 --plan plan-tag2.json --plan plan-dev2.json
    expect "the branch and the tag advanced between assignments: run 2 takes the new commits" "$DEV_SHA_2 $srcB $TAG_SHA_2 $srcB" \
      "$(jq -r '"\(.sources["factum-dev"].resolved.rev) \(.sources["factum-dev"].resolved.storePath) \(.sources["factum-release"].resolved.rev) \(.sources["factum-release"].resolved.storePath)"' o2/run.json)"
    expect "run 1 stays on its captured commits" "true" "$(cmp -s run1.before o1/run.json && echo true || echo false)"
    expect "two runs with different sources have different run digests" "true" "$([ "$(jq -r .digests.run o1/run.json)" != "$(jq -r .digests.run o2/run.json)" ] && echo true || echo false)"

    : >"$FAKE_NIX_LOG"
    rc=0; env -u GH_TOKEN "$assignTool" --template template-private.json --run r3 --out o3 --plan plan-tag1.json --plan plan-dev1.json 2>err || rc=$?
    expect "private source without GH_TOKEN: exit 5, class credential, nothing fetched" "5 credential 0" "$rc $(class err) $(stat -c %s "$FAKE_NIX_LOG")"
    rc=0; GH_TOKEN=$'bad\ntoken' assign --template template-private.json --run r3 --out o3 --plan plan-tag1.json --plan plan-dev1.json 2>err || rc=$?
    expect "a token with an unexpected shape is refused before any fetch" "5 credential 0" "$rc $(class err) $(stat -c %s "$FAKE_NIX_LOG")"
    GH_TOKEN=ghp_testsecret4711 assign --template template-private.json --run r3 --out o3 --plan plan-tag1.json --plan plan-dev1.json >out 2>err
    expect "the token reaches nix as an access-token for the private source only" "1" "$(grep -c 'access-tokens = github.com=ghp_testsecret4711' "$FAKE_NIX_LOG")"
    expect "the token is in no manifest, output, HOME or run directory" "" "$(grep -rl ghp_testsecret4711 out err o3 "$HOME" || true)"
    rc=0; FAKE_NIX_FAIL=$TAG_SHA_1 GH_TOKEN=ghp_testsecret4711 assign --template template-private.json --run r4 --out o4 --plan plan-tag1.json --plan plan-dev1.json 2>err || rc=$?
    expect "a GitHub fetch failure of the private source: exit 4, class github, token redacted" "4 github true false" "$rc $(class err) $(has err '<redacted>') $(has err ghp_testsecret4711)"
    expect "a failed assignment publishes no run manifest" "false" "$(exists o4/run.json)"

    : >"$FAKE_NIX_LOG"
    FAKE_NIX_FAIL=github materialize --run o1/run.json --template template.json --root i1
    FAKE_NIX_FAIL=github materialize --run o1/run.json --template template.json --root i2
    expect "materialize fetches nothing" "0" "$(stat -c %s "$FAKE_NIX_LOG")"
    expect "materialized.json: a private copy for the writable source, store paths for the rest" \
      "factum rw $PWD/i1/workspace/factum /workspace/factum $WRITABLE_REV $hashA $srcA | factum-dev ro $srcA /workspace/factum-dev $DEV_SHA_1 $hashA $srcA | factum-pinned ro $srcB /workspace/factum-pinned $PINNED_REV $hashB $srcB | factum-release ro $srcA /workspace/factum-release $TAG_SHA_1 $hashA $srcA" \
      "$(jq -r '.sources | to_entries | map("\(.key) \(.value.mode) \(.value.source) \(.value.path) \(.value.rev) \(.value.narHash) \(.value.storePath)") | join(" | ")' i1/materialized.json)"
    expect "materialized.json: kind, run and template carried over" "agent-runtime-instance r1 true /workspace" \
      "$(jq -r '"\(.kind) \(.run.id) \(.template.digests.template | test("^[0-9a-f]{64}$")) \(.workspace)"' i1/materialized.json)"
    expect "instance 1 equals the pinned tree, instance 2 equals instance 1" "true true" \
      "$(diff -r --no-dereference "$srcA" i1/workspace/factum >/dev/null && echo true || echo false) $(diff -r --no-dereference i1/workspace/factum i2/workspace/factum >/dev/null && echo true || echo false)"
    expect "the writable source is export-pending" "factum" "$(cat i1/export-pending)"
    echo change >>i1/workspace/factum/README
    printf 'fn new() {}\n' >i1/workspace/factum/src/new.rs
    rm i1/workspace/factum/src/lib.rs
    printf '\000\002\003' >i1/workspace/factum/bin.dat
    chmod 644 i1/workspace/factum/script.sh
    ln -sfn bin.dat i1/workspace/factum/link
    expect "writes in one instance are invisible in the other" "a1 false true" \
      "$(cat i2/workspace/factum/README) $(exists i2/workspace/factum/src/new.rs) $(exists i2/workspace/factum/src/lib.rs)"
    rc=0; materialize --run o1/run.json --template template.json --root i1 2>err || rc=$?
    expect "materializing twice is refused" "1 state" "$rc $(class err)"
    mkdir -p i7/workspace
    rc=0; materialize --run o1/run.json --template template.json --root i7 2>err || rc=$?
    expect "a root with a foreign workspace is refused, not cleaned" "1 state true" "$rc $(class err) $(exists i7/workspace)"

    jq --arg h "$hashB" '.sources.factum.resolved.narHash = $h' o1/run.json >tampered-lock.json
    rc=0; materialize --run tampered-lock.json --template template.json --root i3 2>err || rc=$?
    expect "a run whose locked source differs from the template: exit 8, class source" "8 source" "$rc $(class err)"
    jq '.sources.factum.path = "/workspace/elsewhere"' o1/run.json >tampered-path.json
    rc=0; materialize --run tampered-path.json --template template.json --root i3 2>err || rc=$?
    expect "a run whose path differs from the template is refused" "8 source" "$rc $(class err)"
    rc=0; materialize --run o1/run.json --template template-private.json --root i3 2>err || rc=$?
    expect "a run against another template is refused" "8 source" "$rc $(class err)"
    jq --arg h "$hashB" '.sources["factum-release"].resolved.narHash = $h' o1/run.json >bad-hash.json
    rc=0; materialize --run bad-hash.json --template template.json --root i3 2>err || rc=$?
    expect "NAR hash mismatch after the writable copy was made: exit 6, class store, nothing left behind" "6 store false false" \
      "$rc $(class err) $(exists i3/workspace) $(exists i3/materialized.json)"
    jq '.sources["factum-release"].resolved.storePath = "/nix/store/../../etc"' o1/run.json >traversal.json
    rc=0; materialize --run traversal.json --template template.json --root i4 2>err || rc=$?
    expect "a store path that is not a top-level store path: exit 6, class store" "6 store" "$rc $(class err)"
    jq '.sources["factum-release"].resolved.storePath = "/nix/store/00000000000000000000000000000000-missing"' o1/run.json >missing.json
    rc=0; materialize --run missing.json --template template.json --root i4 2>err || rc=$?
    expect "a missing store path is a store failure, not a GitHub one" "6 store true" "$rc $(class err) $(has err 'not a GitHub one')"
    jq --arg e "$escape" --arg h "$hashE" '.sources["factum-release"].resolved += {storePath: $e, narHash: $h}' o1/run.json >escape.json
    rc=0; materialize --run escape.json --template template.json --root i6 2>err || rc=$?
    expect "a symlink escaping its tree: exit 8, class source, nothing left behind" "8 source false" "$rc $(class err) $(exists i6/workspace)"

    rc=0; reclaim --root i1 2>err || rc=$?
    expect "reclaim refuses while export is pending" "1 state true" "$rc $(class err) $(exists i1/workspace/factum)"
    export_ --root i1 --out x1
    expect "export: changed paths cover content, a new file, a deletion, a binary, a mode and a symlink" \
      '["README","bin.dat","link","script.sh","src/lib.rs","src/new.rs"]' "$(jq -c .changedPaths x1/factum.json)"
    expect "export: the patch carries the binary and the mode change" "true true true" \
      "$(has x1/factum.patch '^GIT binary patch') $(has x1/factum.patch '^new mode 100644') $(has x1/factum.patch '^+change')"
    expect "export: base and patch digest recorded" "$WRITABLE_REV $srcA true" \
      "$(jq -r '"\(.base.rev) \(.base.storePath) \(.patchSha256 | test("^[0-9a-f]{64}$"))"' x1/factum.json)"
    cp -a "$srcA" fresh && chmod -R u+w fresh
    (cd fresh && git apply "../x1/factum.patch")
    expect "the patch reapplied to a fresh checkout of the base reproduces the instance" "true 644 bin.dat" \
      "$(diff -r --no-dereference fresh i1/workspace/factum >/dev/null && echo true || echo false) $(stat -c %a fresh/script.sh) $(readlink fresh/link)"
    expect "export.json counts the changed source; the marker is cleared" "agent-runtime-export 6 false" \
      "$(jq -r '"\(.kind) \(.sources.factum.changed)"' x1/export.json) $(exists i1/export-pending)"
    rc=0; export_ --root i1 --out x1b 2>err || rc=$?
    expect "exporting twice is refused" "1 state" "$rc $(class err)"
    reclaim --root i1
    expect "reclaim after export removes the workspace and keeps the record" "false true true" \
      "$(exists i1/workspace) $(exists i1/reclaimed) $(exists i1/materialized.json)"
    rc=0; export_ --root i1 --out x1c 2>err || rc=$?
    expect "export after reclaim is refused" "1 state" "$rc $(class err)"
    export_ --root i2 --out x2
    expect "an untouched instance exports an empty patch" "0 0" "$(jq -r '.sources.factum.changed' x2/export.json) $(stat -c %s x2/factum.patch)"

    rc=0; env PATH=/var/empty "$shippedReclaim" 2>err || rc=$?
    expect "the shipped tool (real nix) builds and reports usage the same way" "2 usage" "$rc $(class err)"
    touch "$out"
  ''
