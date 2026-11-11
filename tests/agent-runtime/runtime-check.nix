# Runtime adapter check against fixture trees; a fake `nix` answers `flake
# prefetch` and `build --out-link` from a table, so the sandbox needs no network.
{
  pkgs,
  lib,
  runtime,
  shipped,
  devenvPlatform,
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
  # answers `flake prefetch` and `build --out-link` from a table; only `hash path`
  # reaches the real nix, anything else is an unexpected call
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
          config=''${NIX_CONFIG:-}
          printf '%s\t%s\n' "$url" "''${config//$'\n'/ | }" >>"$FAKE_NIX_LOG"
          if [ -n "''${FAKE_NIX_FAIL:-}" ] && [[ $url == *"$FAKE_NIX_FAIL"* ]]; then
            echo "error: unable to download '$url': HTTP 401 (config: ''${NIX_CONFIG:-none})" >&2
            exit 1
          fi
          sp=$(awk -F '\t' -v u="$url" '$1 == u { print $2 }' "$FAKE_NIX_TABLE")
          [ -n "$sp" ] || { echo "error: $url is not in the prefetch table" >&2; exit 1; }
          jq -n --arg h "$(${realNix} --extra-experimental-features nix-command hash path "$sp")" --arg p "$sp" \
            '{hash: $h, storePath: $p, locked: {}}'
          ;;
        *" build "*)
          link="" target=""
          while [ $# -gt 0 ]; do
            case $1 in
              --out-link) link=$2; shift 2 ;;
              --extra-experimental-features) shift 2 ;;
              build) shift ;;
              *) [ -z "$target" ] || { echo "error: fake nix: one installable expected" >&2; exit 1; }; target=$1; shift ;;
            esac
          done
          [ -n "$link" ] && [ -n "$target" ] || { echo "error: fake nix: build --out-link LINK PATH" >&2; exit 1; }
          [ -e "$target" ] || { echo "error: path '$target' is not valid" >&2; exit 1; }
          ln -sfn "$target" "$link"
          ;;
        *" hash path "*) exec ${realNix} "$@" ;;
        *) echo "error: fake nix: unexpected call: $*" >&2; exit 1 ;;
      esac
    '';
  };
  tools = import ../../modules/agent-runtime/runtime.nix {
    inherit lib pkgs;
    nix = fakeNix;
  };
  placeholder = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  writableRev = lib.strings.replicate 40 "a";
  pinnedRev = lib.strings.replicate 40 "b";
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
          lock = lockOf (writableRev) srcA;
          path = "/workspace/factum";
          writable = true;
        };
        factum-pinned = {
          github = "sammasak/factum";
          ref = {
            type = "commit";
            value = pinnedRev;
          };
          lock = lockOf (pinnedRev) srcB;
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
      skillsSource = lockOf (pinnedRev) srcB;
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
  tightManifests =
    (runtime.evalManifests {
      modules = [
        template
        { sam.agentRuntime.templates.fixture.filesystem.workspaceBudget.inodes = 2; }
      ];
    }).manifestDir;
in
pkgs.runCommand "agent-runtime-runtime"
  {
    nativeBuildInputs = [
      pkgs.git
      pkgs.jq
      pkgs.nix
      pkgs.util-linux
    ];
    inherit
      manifests
      tightManifests
      srcA
      srcB
      escape
      writableRev
      pinnedRev
      ;
    assignTool = lib.getExe tools.assign;
    materializeTool = lib.getExe tools.materialize;
    exportTool = lib.getExe tools.export;
    reclaimTool = lib.getExe tools.reclaim;
    shippedReclaim = lib.getExe shipped.reclaim;
    instanceTool = lib.getExe tools.instance;
    preflightTool = lib.getExe tools.preflight;
    bootTool = lib.getExe tools.boot;
    planJq = "${devenvPlatform}/modules/prepare/plan.jq";
  }
  ''
    set -euo pipefail
    fail() { printf 'agent-runtime-runtime: %s\n' "$1" >&2; exit 1; }
    expect() { [ "$2" = "$3" ] || fail "$1: expected '$2', got '$3'"; echo "ok   - $1"; }
    class() { tail -n 1 "$1" | jq -r '.error.class' 2>/dev/null || echo "(no json error)"; }
    holds() { "$@" >/dev/null 2>&1 && echo true || echo false; }
    exists() { holds test -e "$1"; }
    has() { holds grep -q -- "$2" "$1"; }
    leaks() { grep -rl ghp_testsecret4711 "$@"; [ $? -le 1 ] || fail "grep failed on $*"; }
    # the tools see nothing but their own runtime inputs
    assign() { env PATH=/var/empty "$assignTool" "$@"; }
    materialize() { env PATH=/var/empty "$materializeTool" "$@"; }
    export_run() { env PATH=/var/empty "$exportTool" "$@"; }
    reclaim() { env PATH=/var/empty "$reclaimTool" "$@"; }
    nar() { nix --extra-experimental-features nix-command hash path "$1"; }
    tamper() { local dir=''${!#}; mkdir -p "$dir" && cp -r o1/gcroots "$dir/" && jq "''${@:1:$#-1}" o1/run.json >"$dir/run.json"; }

    export HOME=$TMPDIR/home FAKE_NIX_LOG=$TMPDIR/nix.log FAKE_NIX_TABLE=$TMPDIR/table
    mkdir -p "$HOME"
    hashA=$(nar "$srcA"); hashB=$(nar "$srcB"); hashEscape=$(nar "$escape")
    TAG_SHA_1=1111111111111111111111111111111111111111
    TAG_SHA_2=2222222222222222222222222222222222222222
    DEV_SHA_1=3333333333333333333333333333333333333333
    DEV_SHA_2=4444444444444444444444444444444444444444
    DEV_SHA_3=5555555555555555555555555555555555555555
    printf 'github:sammasak/factum/%s\t%s\n' "$TAG_SHA_1" "$srcA" "$TAG_SHA_2" "$srcB" "$DEV_SHA_1" "$srcA" "$DEV_SHA_2" "$srcB" \
      "$DEV_SHA_3" /nix/store/00000000000000000000000000000000-gone >"$FAKE_NIX_TABLE"
    fill() { jq --arg a "$hashA" --arg b "$hashB" '.sources.factum.locked.narHash = $a | .sources["factum-pinned"].locked.narHash = $b' "$1"; }
    fill "$manifests/fixture.json" >template.json
    fill "$tightManifests/fixture.json" >template-tight.json
    jq '.sources["factum-release"].access = "private"' template.json >template-private.json
    # every plan is written by devenv-platform's own prepare:plan program (#92/#112, the pinned input), not a copy of
    # its shape: a schema change there fails here on the input bump
    plan() {
      jq -Sn --arg repo sammasak/factum --arg ref "$1" --arg sha "$2" --arg subproject "''${3:-.}" --arg system x86_64-linux -f "$planJq"
    }
    plan v0.2.0 "$TAG_SHA_1" >plan-tag1.json
    plan v0.2.0 "$TAG_SHA_2" >plan-tag2.json
    plan dev "$DEV_SHA_1" >plan-dev1.json
    plan dev "$DEV_SHA_2" >plan-dev2.json
    plan dev "$DEV_SHA_3" >plan-dev3.json
    plan v0.1.0 "$TAG_SHA_1" >plan-wrong-ref.json
    plan v0.2.0 zz >plan-bad-sha.json
    plan v0.2.0 "$TAG_SHA_1" src >plan-subproject.json

    rc=0; assign 2>err || rc=$?
    expect "no arguments: exit 2, class usage as a JSON line" "2 usage" "$rc $(class err)"
    rc=0; assign --template template.json --run >/dev/null 2>err || rc=$?
    expect "a flag without its value: exit 2, class usage" "2 usage" "$rc $(class err)"
    rc=0; assign --template template.json --run r0 --out o0 2>err || rc=$?
    expect "assignment sources without plans: exit 3, class plan" "3 plan" "$rc $(class err)"
    expect "the plans are prepare:plan v1 documents (devenv-platform's plan.jq), source pinned to one commit" \
      "1 sammasak/factum dev $DEV_SHA_1 . https://github.com/sammasak/factum" \
      "$(jq -r '"\(.schema_version) \(.source.repo) \(.source.ref) \(.source.sha) \(.source.subproject) \(.source.url)"' plan-dev1.json)"
    rc=0; : >"$FAKE_NIX_LOG"; assign --template template.json --run r0 --out o0 --plan plan-tag1.json 2>err || rc=$?
    expect "missing ref: the branch has no plan (prepare:plan found no such ref): exit 3, class plan, nothing fetched" "3 plan 0 true" \
      "$rc $(class err) $(stat -c %s "$FAKE_NIX_LOG") $(has err 'no prepare:plan given for sammasak/factum@dev')"
    rc=0; assign --template template.json --run r0 --out o0 --plan plan-wrong-ref.json --plan plan-dev1.json 2>err || rc=$?
    expect "a plan for the right repo but another ref does not match" "3 plan true" "$rc $(class err) $(has err 'no prepare:plan given for sammasak/factum@v0.2.0')"
    rc=0; assign --template template.json --run r0 --out o0 --plan plan-tag1.json --plan plan-tag2.json --plan plan-dev1.json 2>err || rc=$?
    expect "two plans that disagree on one ref are refused" "3 plan" "$rc $(class err)"
    rc=0; assign --template template.json --run r0 --out o0 --plan plan-bad-sha.json --plan plan-dev1.json 2>err || rc=$?
    expect "a malformed plan (sha not 40 hex) is refused" "3 plan" "$rc $(class err)"
    rc=0; assign --template template.json --run r0 --out o0 --plan plan-subproject.json --plan plan-dev1.json 2>err || rc=$?
    expect "a subproject plan is refused: the adapter materializes whole repositories" "3 plan" "$rc $(class err)"
    rc=0; assign --template template.json --run r0 --out o0 --plan plan-tag1.json --plan plan-dev3.json 2>err || rc=$?
    expect "a prefetched path absent from the store: exit 6, class store" "6 store" "$rc $(class err)"
    expect "a refused assignment publishes neither a run manifest nor GC roots" "false false" "$(exists o0/run.json) $(exists o0/gcroots)"

    : >"$FAKE_NIX_LOG"
    assign --template template.json --run r1 --out o1 --plan plan-tag1.json --plan plan-dev1.json
    expect "run.json: every source keeps repo, requested ref, path, mode and how it was resolved" \
      "$(printf '%s\n' "factum sammasak/factum branch main /workspace/factum true lock" \
        "factum-dev sammasak/factum branch dev /workspace/factum-dev false plan" \
        "factum-pinned sammasak/factum commit $pinnedRev /workspace/factum-pinned false lock" \
        "factum-release sammasak/factum tag v0.2.0 /workspace/factum-release false plan")" \
      "$(jq -r '.sources | to_entries[] | "\(.key) \(.value.github) \(.value.ref.type) \(.value.ref.value) \(.value.path) \(.value.writable) \(.value.resolved.by)"' o1/run.json)"
    expect "run.json: resolved commits and store paths per source" \
      "$(printf '%s\n' "$writableRev $hashA $srcA" "$DEV_SHA_1 $hashA $srcA" "$pinnedRev $hashB $srcB" "$TAG_SHA_1 $hashA $srcA")" \
      "$(jq -r '.sources[] | .resolved | "\(.rev) \(.narHash) \(.storePath)"' o1/run.json)"
    expect "run.json: each plan-resolved source names the sha256 of the plan document that resolved it" \
      "$(sha256sum plan-dev1.json | cut -d' ' -f1) $(sha256sum plan-tag1.json | cut -d' ' -f1) null null" \
      "$(jq -r '"\(.sources["factum-dev"].resolved.plan) \(.sources["factum-release"].resolved.plan) \(.sources.factum.resolved.plan) \(.sources["factum-pinned"].resolved.plan)"' o1/run.json)"
    expect "run.json: kind, template digests, no lock field survives" "agent-runtime-run true false" \
      "$(jq -r '"\(.kind) \(.template.digests.template | test("^[0-9a-f]{64}$")) \([.sources[] | has("locked")] | any)"' o1/run.json)"
    expect "digests.run is the sha256 of the canonical run id, template digests, workspace and sources" \
      "$(jq -cS '{run: {id: .run.id}, template, workspace, sources}' o1/run.json | sha256sum | cut -d' ' -f1)" "$(jq -r .digests.run o1/run.json)"
    expect "every source is GC-rooted under the run directory" "$srcA $srcA $srcB $srcA" \
      "$(readlink o1/gcroots/factum) $(readlink o1/gcroots/factum-dev) $(readlink o1/gcroots/factum-pinned) $(readlink o1/gcroots/factum-release)"
    expect "only the two assignment-resolved sources are prefetched, neither with a token" "2 0" \
      "$(wc -l <"$FAKE_NIX_LOG") $(grep -c access-tokens "$FAKE_NIX_LOG" || true)"
    rc=0; assign --template template.json --run r1 --out o1 --plan plan-tag1.json --plan plan-dev1.json 2>err || rc=$?
    expect "a run is assigned once" "1 state" "$rc $(class err)"
    mkdir -p o-locked
    ( flock 9; sleep 3 ) 9>o-locked/.lock &
    sleep 1
    rc=0; assign --template template.json --run r1 --out o-locked --plan plan-tag1.json --plan plan-dev1.json 2>err || rc=$?
    expect "a run directory held by another assignment is refused" "1 state" "$rc $(class err)"
    wait
    assign --template template.json --run r2 --out o2 --plan plan-tag2.json --plan plan-dev2.json
    expect "the branch and the tag advanced between assignments: run 2 takes the new commits" "$DEV_SHA_2 $srcB $TAG_SHA_2 $srcB" \
      "$(jq -r '"\(.sources["factum-dev"].resolved.rev) \(.sources["factum-dev"].resolved.storePath) \(.sources["factum-release"].resolved.rev) \(.sources["factum-release"].resolved.storePath)"' o2/run.json)"
    assign --template template.json --run r9 --out o9a --plan plan-tag1.json --plan plan-dev1.json
    assign --template template.json --run r9 --out o9b --plan plan-tag2.json --plan plan-dev2.json
    assign --template template.json --run r9 --out o9c --plan plan-tag1.json --plan plan-dev1.json
    expect "one run id with other sources has another digest; the same sources give the same digest" "true true" \
      "$(holds test "$(jq -r .digests.run o9a/run.json)" != "$(jq -r .digests.run o9b/run.json)") $(holds test "$(jq -r .digests.run o9a/run.json)" = "$(jq -r .digests.run o9c/run.json)")"

    : >"$FAKE_NIX_LOG"
    rc=0; env -u GH_TOKEN PATH=/var/empty "$assignTool" --template template-private.json --run r3 --out o3 --plan plan-tag1.json --plan plan-dev1.json 2>err || rc=$?
    expect "private source without GH_TOKEN: exit 5, class credential, nothing fetched" "5 credential 0" "$rc $(class err) $(stat -c %s "$FAKE_NIX_LOG")"
    rc=0; GH_TOKEN=$'bad\ntoken' assign --template template-private.json --run r3 --out o3 --plan plan-tag1.json --plan plan-dev1.json 2>err || rc=$?
    expect "a token with an unexpected shape is refused before any fetch" "5 credential 0" "$rc $(class err) $(stat -c %s "$FAKE_NIX_LOG")"
    GH_TOKEN=ghp_testsecret4711 NIX_CONFIG='warn-dirty = false' assign --template template-private.json --run r3 --out o3 --plan plan-tag1.json --plan plan-dev1.json >out 2>err
    tab=$(printf '\t')
    expect "the token reaches nix for the private source only, appended to the caller's NIX_CONFIG" "true false" \
      "$(holds grep -qF "$TAG_SHA_1''${tab}warn-dirty = false | access-tokens = github.com=ghp_testsecret4711" "$FAKE_NIX_LOG") $(holds grep -q "$DEV_SHA_1.*access-tokens" "$FAKE_NIX_LOG")"
    expect "the token is in no manifest, output, HOME or run directory" "" "$(leaks out err o3 "$HOME")"
    rc=0; FAKE_NIX_FAIL=$TAG_SHA_1 GH_TOKEN=ghp_testsecret4711 assign --template template-private.json --run r4 --out o4 --plan plan-tag1.json --plan plan-dev1.json 2>err || rc=$?
    expect "a GitHub fetch failure of the private source: exit 4, class github, token redacted" "4 github true false" "$rc $(class err) $(has err '<redacted>') $(has err ghp_testsecret4711)"
    expect "a failed assignment publishes neither a run manifest nor GC roots" "false false" "$(exists o4/run.json) $(exists o4/gcroots)"

    : >"$FAKE_NIX_LOG"
    FAKE_NIX_FAIL=github materialize --run o1 --template template.json --root i1
    FAKE_NIX_FAIL=github materialize --run o1 --template template.json --root i2
    expect "materialized.json: a private copy for the writable source, store paths for the rest" \
      "$(printf '%s\n' "factum rw $PWD/i1/workspace/factum /workspace/factum $writableRev $hashA $srcA" \
        "factum-dev ro $srcA /workspace/factum-dev $DEV_SHA_1 $hashA $srcA" \
        "factum-pinned ro $srcB /workspace/factum-pinned $pinnedRev $hashB $srcB" \
        "factum-release ro $srcA /workspace/factum-release $TAG_SHA_1 $hashA $srcA")" \
      "$(jq -r '.sources | to_entries[] | "\(.key) \(.value.mode) \(.value.source) \(.value.path) \(.value.rev) \(.value.narHash) \(.value.storePath)"' i1/materialized.json)"
    expect "run 1 materialized after the branch advanced still carries its captured commits" "$DEV_SHA_1 $TAG_SHA_1" \
      "$(jq -r '"\(.sources["factum-dev"].rev) \(.sources["factum-release"].rev)"' i1/materialized.json)"
    expect "materialized.json: kind, run and template carried over" "agent-runtime-instance r1 true /workspace" \
      "$(jq -r '"\(.kind) \(.run.id) \(.template.digests.template | test("^[0-9a-f]{64}$")) \(.workspace)"' i1/materialized.json)"
    expect "instance 2 binds its own copy" "$PWD/i2/workspace/factum" "$(jq -r .sources.factum.source i2/materialized.json)"
    expect "instance 1 equals the pinned tree, instance 2 equals instance 1" "true true" \
      "$(holds diff -r --no-dereference "$srcA" i1/workspace/factum) $(holds diff -r --no-dereference i1/workspace/factum i2/workspace/factum)"
    expect "the writable source is export-pending" "factum" "$(cat i1/export-pending)"
    echo change >>i1/workspace/factum/README
    printf 'fn new() {}\n' >i1/workspace/factum/src/new.rs
    rm i1/workspace/factum/src/lib.rs
    printf '\000\002\003' >i1/workspace/factum/bin.dat
    chmod 644 i1/workspace/factum/script.sh
    ln -sfn bin.dat i1/workspace/factum/link
    expect "writes in one instance are invisible in the other" "a1 false true" \
      "$(cat i2/workspace/factum/README) $(exists i2/workspace/factum/src/new.rs) $(exists i2/workspace/factum/src/lib.rs)"
    rc=0; materialize --run o1 --template template.json --root i1 2>err || rc=$?
    expect "materializing twice is refused" "1 state" "$rc $(class err)"
    mkdir -p i7/workspace
    rc=0; materialize --run o1 --template template.json --root i7 2>err || rc=$?
    expect "a root with a foreign workspace is refused, not cleaned" "1 state true" "$rc $(class err) $(exists i7/workspace)"
    rc=0; materialize --run o1 --template template-tight.json --root i-tight 2>err || rc=$?
    expect "a run against another template is refused" "8 source" "$rc $(class err)"
    assign --template template-tight.json --run r5 --out o5 --plan plan-tag1.json --plan plan-dev1.json
    : >"$FAKE_NIX_LOG"
    rc=0; materialize --run o5 --template template-tight.json --root i-tight 2>err || rc=$?
    expect "writable copies beyond the workspace budget: exit 7, class budget, nothing left behind" "7 budget false" "$rc $(class err) $(exists i-tight/workspace)"

    tamper --arg h "$hashB" '.sources.factum.resolved.narHash = $h' t-lock
    rc=0; materialize --run t-lock --template template.json --root i3 2>err || rc=$?
    expect "a run whose locked source differs from the template: exit 8, class source" "8 source" "$rc $(class err)"
    tamper '.sources.factum.path = "/workspace/elsewhere"' t-path
    rc=0; materialize --run t-path --template template.json --root i3 2>err || rc=$?
    expect "a run whose path differs from the template is refused" "8 source" "$rc $(class err)"
    tamper '.template.digests.template = "0000000000000000000000000000000000000000000000000000000000000000"' t-digest
    rc=0; materialize --run t-digest --template template.json --root i3 2>err || rc=$?
    expect "a run with another template digest is refused" "8 source" "$rc $(class err)"
    tamper --arg b "$srcB" --arg h "$hashB" '.sources["factum-release"].resolved += {storePath: $b, narHash: $h}' t-swap
    rc=0; materialize --run t-swap --template template.json --root i3 2>err || rc=$?
    expect "an assignment-resolved source swapped for another valid store path is refused: the GC root is the anchor" "8 source" "$rc $(class err)"
    tamper --arg h "$hashB" '.sources["factum-release"].resolved.narHash = $h' t-hash
    rc=0; materialize --run t-hash --template template.json --root i3 2>err || rc=$?
    expect "NAR hash mismatch after the writable copy was made: exit 6, class store, nothing left behind" "6 store false false false" \
      "$rc $(class err) $(exists i3/workspace) $(exists i3/materialized.json) $(exists i3/export-pending)"
    tamper '.sources["factum-release"].resolved.storePath = "/nix/store/../../etc"' t-traversal
    rc=0; materialize --run t-traversal --template template.json --root i4 2>err || rc=$?
    expect "a store path that is not a top-level store path: exit 6, class store" "6 store" "$rc $(class err)"
    tamper '.sources["factum-release"].resolved.storePath = "/nix/store/00000000000000000000000000000000-missing"' t-missing
    rc=0; materialize --run t-missing --template template.json --root i4 2>err || rc=$?
    expect "a missing store path is a store failure, not a GitHub one" "6 store true" "$rc $(class err) $(has err 'not a GitHub one')"
    tamper --arg e "$escape" --arg h "$hashEscape" '.sources["factum-release"].resolved += {storePath: $e, narHash: $h}' t-escape
    ln -sfn "$escape" t-escape/gcroots/factum-release
    rc=0; materialize --run t-escape --template template.json --root i6 2>err || rc=$?
    expect "a symlink escaping its tree: exit 8, class source, nothing left behind" "8 source false" "$rc $(class err) $(exists i6/workspace)"

    rc=0; reclaim --root i1 2>err || rc=$?
    expect "reclaim refuses while export is pending" "1 state true" "$rc $(class err) $(exists i1/workspace/factum)"
    export_run --root i1 --out x1
    expect "export: changed paths cover content, a new file, a deletion, a binary, a mode and a symlink" \
      '["README","bin.dat","link","script.sh","src/lib.rs","src/new.rs"]' "$(jq -c .changedPaths x1/factum.json)"
    expect "export: the patch carries the binary and the mode change" "true true true" \
      "$(has x1/factum.patch '^GIT binary patch') $(has x1/factum.patch '^new mode 100644') $(has x1/factum.patch '^+change')"
    expect "export: base, tree and patch digest recorded" "$writableRev $srcA true true" \
      "$(jq -r '"\(.base.rev) \(.base.storePath) \(.tree | test("^[0-9a-f]{40}$")) \(.patchSha256 | test("^[0-9a-f]{64}$"))"' x1/factum.json)"
    cp -a "$srcA" fresh && chmod -R u+w fresh
    (cd fresh && git apply "../x1/factum.patch")
    expect "the patch reapplied to a fresh checkout of the base reproduces the instance" "true 644 bin.dat" \
      "$(holds diff -r --no-dereference fresh i1/workspace/factum) $(stat -c %a fresh/script.sh) $(readlink fresh/link)"
    expect "export.json counts the changed source; the marker is cleared, the tree recorded" "agent-runtime-export 6 false true" \
      "$(jq -r '"\(.kind) \(.sources.factum.changed)"' x1/export.json) $(exists i1/export-pending) $(holds test "$(jq -r .factum i1/exported.json)" = "$(jq -r .tree x1/factum.json)")"
    rc=0; export_run --root i1 --out x1b 2>err || rc=$?
    expect "exporting twice is refused" "1 state" "$rc $(class err)"
    echo late >>i1/workspace/factum/README
    rc=0; reclaim --root i1 2>err || rc=$?
    expect "a checkout edited after its export is not reclaimed" "1 state true" "$rc $(class err) $(exists i1/workspace/factum)"
    printf 'a1\nchange\n' >i1/workspace/factum/README
    reclaim --root i1
    expect "reclaim after export removes the workspace and keeps the record" "false true true" \
      "$(exists i1/workspace) $(exists i1/reclaimed) $(exists i1/materialized.json)"
    reclaim --root i1
    echo "ok   - reclaiming twice is a no-op"
    rc=0; export_run --root i1 --out x1c 2>err || rc=$?
    expect "export after reclaim is refused" "1 state" "$rc $(class err)"

    # ignore rules cannot hide state: the pinned tree's own .gitignore applies to new paths only
    FAKE_NIX_FAIL=github materialize --run o1 --template template.json --root i8
    printf '*.log\n' >i8/workspace/factum/.gitignore
    printf 'hidden\n' >i8/workspace/factum/new.log
    printf 'fn a() { changed }\n' >i8/workspace/factum/src/lib.rs
    export_run --root i8 --out x8
    expect "a checkout's own ignore file hides nothing: new and changed paths are exported" \
      '[".gitignore","new.log","src/lib.rs"]' "$(jq -c .changedPaths x8/factum.json)"
    FAKE_NIX_FAIL=github materialize --run o1 --template template.json --root i9
    mkdir -p i9/workspace/factum/sub && printf 'gitdir: /nonexistent\n' >i9/workspace/factum/sub/.git
    rc=0; export_run --root i9 --out x9 2>err || rc=$?
    expect "a nested repository in a checkout is refused, the marker stays" "9 export true false" "$rc $(class err) $(exists i9/export-pending) $(exists x9/export.json)"
    rm i9/workspace/factum/sub/.git
    export_run --root i9 --out x9
    expect "an untouched instance exports an empty patch" "0 0" "$(jq -r '.sources.factum.changed' x9/export.json) $(stat -c %s x9/factum.patch)"
    export_run --root i2 --out x2
    expect "materialize, export and reclaim fetch nothing" "0" "$(stat -c %s "$FAKE_NIX_LOG")"

    # a run without writable sources (docs-reviewer's shape): export writes only export.json and reclaim proceeds
    jq 'del(.sources.factum, .sources["factum-dev"], .sources["factum-release"])' template.json >template-ro.json
    assign --template template-ro.json --run r-ro --out o-ro
    materialize --run o-ro --template template-ro.json --root i-ro
    expect "a read-only run: materialized, nothing export-pending" "ro 0" "$(jq -r '.sources["factum-pinned"].mode' i-ro/materialized.json) $(wc -c <i-ro/export-pending)"
    export_run --root i-ro --out x-ro
    reclaim --root i-ro
    expect "a read-only run exports only export.json and reclaims" "export.json {} true" \
      "$(ls x-ro) $(jq -c .sources x-ro/export.json) $(exists i-ro/reclaimed)"
    # what a patch cannot carry is named in droppedPaths, not lost silently
    FAKE_NIX_FAIL=github materialize --run o1 --template template.json --root i10
    mkdir i10/workspace/factum/emptydir i10/workspace/factum/.git
    export_run --root i10 --out x10
    expect "an empty directory and a top-level .git are listed as dropped, the patch is empty" '[".git","emptydir/"] 0 2' \
      "$(jq -c .droppedPaths x10/factum.json) $(jq -r .sources.factum.changed x10/export.json) $(jq -r .sources.factum.dropped x10/export.json)"
    # one materialize per root: a held root lock refuses before any state check or cleanup
    mkdir -p i11
    ( flock 9; sleep 3 ) 9>i11/.lock &
    sleep 1
    rc=0; materialize --run o1 --template template.json --root i11 2>err || rc=$?
    expect "materialize refuses a root held by another materialize, export or reclaim" "1 state false" "$rc $(class err) $(exists i11/workspace)"
    wait

    # preflight is honest about what it cannot see (no root here: a 0000 state directory is unreadable)
    jq -n '{kind: "agent-runtime-host", schemaVersion: 1, enable: true, eligibleTemplates: ["fixture"], maxConcurrentInstances: 1,
      reserve: {cpus: 0, memoryMiB: 0, diskMiB: 0}}' >host.json
    preflight() { env PATH=/var/empty "$preflightTool" --host host.json --no-herdr "$@" || true; }
    verdicts() { grep -E "^(PASS|FAIL) ($1):" "$2" | cut -d: -f1 | tr '\n' ' '; }
    mkdir -p pf-open pf-closed && chmod 000 pf-closed
    preflight --state pf-open --template template.json >pf
    expect "preflight on a readable, empty state directory: no instance, a free slot, Herdr skipped on request" \
      "PASS herdr PASS instances PASS capacity " "$(verdicts 'herdr|instances|capacity' pf)"
    expect "preflight: every store path the manifest names exists; a template without egress needs no forwarding" \
      "PASS store PASS egress-forwarding " "$(verdicts 'store|egress-forwarding' pf)"
    preflight --state pf-closed --template template.json >pf
    expect "an unreadable state directory fails everything that depends on the reservations, and the verdict" \
      "FAIL reservations FAIL memory FAIL cpu FAIL instances FAIL capacity NO-GO" \
      "$(verdicts 'reservations|memory|cpu|instances|capacity' pf)$(tail -n 1 pf | cut -d' ' -f2)"
    chmod 700 pf-closed
    jq '.skills.source.storePath = "/nix/store/00000000000000000000000000000000-gone"' template.json >template-gone.json
    preflight --state pf-open --template template-gone.json >pf
    expect "a store path the manifest names but the host lacks is a no-go, named" "FAIL store true" \
      "$(verdicts store pf | tr -d ' ' | sed 's/FAIL/FAIL /') $(has pf 00000000000000000000000000000000-gone)"
    jq '.policies.network = {egress: "allowlist", allow: ["api.example.org"]}' template.json >template-egress.json
    preflight --state pf-open --template template-egress.json >pf
    # the builder's own setting decides which way: the sandbox may or may not share the host's network namespace
    if [ "$(cat /proc/sys/net/ipv4/ip_forward)" = 1 ]; then want=PASS; else want=FAIL; fi
    expect "an egress allowlist is a go only with IPv4 forwarding, read from the host" "$want egress-forwarding true" \
      "$(verdicts egress-forwarding pf)$(has pf 'egress-forwarding: net.ipv4.ip_forward=')"

    # settle (#reboot): instance directories as a boot finds them, built by hand (create needs loop mounts
    # and real root); a user namespace gives the mounts and the ownership the lifecycle expects
    printf 'ghp_testsecret4711' >tok
    cat >settle.sh <<'SETTLE'
    S=$PWD/st R=$PWD/rn
    inst() { env PATH=/var/empty "$instanceTool" --state "$S" --run "$R" "$@"; }
    n=0
    mk() {  # ID: a created instance
      local b=$S/$1 v
      n=$((n + 1))
      mkdir -p "$b/img" "$b/vol"
      for v in workspace home tmp cache output; do mkdir "$b/vol/$v"; mount -t tmpfs tmpfs "$b/vol/$v"; done
      umount "$b/vol/workspace" && mount --bind "$PWD/ws/$1" "$b/vol/workspace"
      echo "512 320 $((1048576 + 65536 * n)) fixture 1" >"$b/reservation"
      cp template.json "$b/template.json"
      jq -n --arg id "$1" --arg r "$(printf '%032x' "$n")" '{schemaVersion: 1, kind: "agent-runtime-instance-record", id: $id,
        task: "sammasak/factum#1", template: {name: "fixture"}, runId: $r}' >"$b/instance.json"
    }
    began() { jq -n --arg at "$2" '{at: $at}' >"$S/$1/starting"; }  # ID AT: the start marker
    ran() { jq -n --argjson c "$2" '{invocation: "", credential: $c}' >"$S/$1/started.json"; }  # ID CREDENTIAL
    down() { jq -n '{outcome: "interrupted", interruptedBy: "host-shutdown", serviceResult: "success"}' >"$S/$1/result.json"; }
    source_of() { jq -n --arg p "$PWD/tok" --arg h "$2" '{path: $p, sha256: $h}' >"$S/$1/cred-source"; }  # ID DIGEST
    file_cred='{"kind":"file","scopes":null,"expiresAt":null}'
    digest=$(sha256sum <tok | cut -d' ' -f1)
    # crashed: started before this boot, outcome never recorded. fresh: the same, but started in this boot
    mk crashed; began crashed 2020-01-01T00:00:00Z; ran crashed null
    echo result >"$S/crashed/vol/output/report.txt"; echo change >>"$S/crashed/vol/workspace/workspace/factum/README"
    mk fresh; began fresh "$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)"
    # recorded by record-exit while the host went down, with a credential read from a host file
    mk keyed; began keyed 2020-01-01T00:00:00Z; ran keyed "$file_cred"; down keyed; source_of keyed "$digest"
    mk rotated; began rotated 2020-01-01T00:00:00Z; ran rotated "$file_cred"; down rotated; source_of rotated "''${digest//[0-9]/a}"
    mk leaky; began leaky 2020-01-01T00:00:00Z; ran leaky "$file_cred"; down leaky; source_of leaky "$digest"
    cp tok "$S/leaky/vol/output/stolen"
    mk made
    mkdir -p "$S/half" && echo "512 320 1048576 fixture 1" >"$S/half/reservation"
    mk ended; began ended 2020-01-01T00:00:00Z; ran ended null
    SERVICE_RESULT=success EXIT_CODE=exited EXIT_STATUS=0 inst record-exit ended
    expect "record-exit on a host that is not going down is unchanged: succeeded, no interruptedBy" "succeeded false" \
      "$(jq -r '"\(.outcome) \(has("interruptedBy"))"' "$S/ended/result.json")"

    mkdir profile && cp template.json profile/fixture.json
    env PATH=/var/empty "$bootTool" --state "$S" --run "$R" --host host.json --profile profile
    expect "boot: each instance settled, rolled back, held or left, by what the boot found" \
      "$(printf '%s\n' "crashed settled interrupted" "ended untouched succeeded" "fresh untouched ambiguous" "half rolled-back incomplete" \
        "keyed settled interrupted" "leaky held interrupted" "made untouched created" "rotated held interrupted")" \
      "$(jq -r '.instances[] | "\(.id) \(.action) \(.state)"' "$R/settle.json")"
    expect "a settled run is gone from the state and the runtime directory, and its reservation with it" "false false false false" \
      "$(exists "$S/crashed") $(exists "$R/crashed") $(exists "$S/keyed") $(exists "$S/half")"
    bundle=$S/exports/crashed.runs/latest
    expect "the crashed run's bundle: outcome interrupted by the host restart, a recovery bundle with its output and patch" \
      "interrupted true interrupted host-restart result true" \
      "$(jq -r '"\(.outcome) \(.recovery)"' "$bundle/bundle.json") $(jq -r '"\(.outcome) \(.interruptedBy)"' "$bundle/result.json") $(cat "$bundle/output/report.txt") $(has "$bundle/sources/factum.patch" '^+change')"
    expect "the run a shutdown interrupted keeps record-exit's word (host-shutdown); its credential was re-read from the host path" \
      "host-shutdown true" "$(jq -r .interruptedBy "$S/exports/keyed.runs/latest/result.json") $(has "$R/settle.json" 'keyed.runs')"
    expect "held, fail closed: a credential that changed since the start, and one found in the output; neither exported nor destroyed" \
      "true true false false true true" \
      "$(has "$R/settle.json" 'cannot be re-read') $(has "$R/settle.json" 'appears in an exported artifact') $(exists "$S/exports/rotated.runs") $(exists "$S/leaky/exported.json") $(exists "$S/rotated/reservation") $(exists "$S/leaky/reservation")"
    expect "nothing was started, and a run of this boot stays ambiguous for the operator" "ambiguous created false" \
      "$(inst status fresh | jq -r .state) $(inst status made | jq -r .state) $(exists "$S/made/starting")"
    expect "status.json: world-readable, states and counts without root, not admit-ready while runs are unresolved" \
      "644 agent-runtime-host-status false 5 1 fresh,leaky,rotated go" \
      "$(stat -c %a "$R/status.json") $(jq -r '"\(.kind) \(.admitReady) \(.reservations.count) \(.reservations.max) \(.unresolved | join(","))"' "$R/status.json") $(jq -r '.preflight.templates[0] | if (.failed | map(select(startswith("instances") or startswith("capacity"))) | length) == 2 then "go" else "bad" end' "$R/status.json")"
    expect "the token is in no status, report, bundle or record" "$S/leaky/vol/output/stolen" "$(leaks "$R" "$S" | sort | tr '\n' ' ' | sed 's/ $//')"
    before=$(jq -c '[.instances[] | {id, action, state}]' "$R/settle.json")
    again=$(inst settle | jq -c '[.instances[] | {id, action, state}]')
    expect "settle again: the settled ones are gone, everything else is found and left as before" \
      "$(jq -c 'map(select(.action != "settled" and .action != "rolled-back"))' <<<"$before")" "$again"
    expect "settle again publishes no second bundle" "1" "$(find "$S/exports/crashed.runs" -mindepth 1 -maxdepth 1 -type d | wc -l)"
    for i in fresh leaky rotated made ended; do inst destroy "$i" --discard >/dev/null; done
    expect "with the leftovers destroyed by hand the host is admit-ready" "true 0 " \
      "$(inst host-status --host host.json | jq -r '"\(.admitReady) \(.reservations.count) \(.unresolved | join(","))"')"
    SETTLE
    # materialized out here: root of a one-id namespace cannot keep a store path's ownership on a copy
    for i in crashed fresh keyed rotated leaky made ended; do
      FAKE_NIX_FAIL=github materialize --run o1 --template template.json --root "ws/$i"
    done
    export -f fail expect class holds exists has leaks
    export instanceTool bootTool
    unshare --user --map-root-user --mount bash -euo pipefail settle.sh

    rc=0; env PATH=/var/empty "$shippedReclaim" 2>err || rc=$?
    expect "the shipped tool (real nix) builds and reports usage the same way" "2 usage" "$rc $(class err)"
    touch "$out"
  ''
