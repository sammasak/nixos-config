# #169 in one QEMU VM: the coding-agent template (modules/agent-runtime/templates/claude-coder.nix)
# with the real Claude Code binary, through the shipped instance lifecycle and the host-side bundle
# verifier. Offline and model-free: no network inside the instance, no real credential. It proves the
# fail-closed auth, the bounded run without egress, a nonempty exported patch the trusted host
# verifies against the pinned revision, the verifier's refusals, and cancellation. A real model turn
# is the owner-gated live step (docs/agent-runtime-coder.md); nothing here claims it.
#   nix build .#packages.x86_64-linux.agent-runtime-coder-test
{ pkgs, lib, rfProto, skills }:
let
  # claude-code is unfree: allowed by name for this evaluation only, as the hosts allow it
  pkgsU = import pkgs.path {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfreePredicate = p: lib.getName p == "claude-code";
  };
  runtime = import ../modules/agent-runtime/lib.nix { inherit lib; pkgs = pkgsU; };
  evaluated = runtime.evalManifests {
    modules = [
      ../modules/agent-runtime/templates/claude-coder.nix
      {
        sam.agentRuntime.pinnedSources = { rf-proto = rfProto; inherit skills; };
        sam.agentRuntime.host = {
          enable = true;
          eligibleTemplates = [ "claude-coder" ];
          maxConcurrentInstances = 1;
          reserve = { memoryMiB = 512; diskMiB = 1024; };
        };
      }
    ];
  };
  tpl = evaluated.templates.claude-coder;
  manifest = "${evaluated.manifestDir}/claude-coder.json";
  I = lib.getExe runtime.tools.instance;
  # Kill after the inner export consumed export-pending, before the outer bundle is published.
  interruptedExport = pkgs.runCommand "agent-runtime-interrupted-export" { } ''
    substitute ${I} "$out" --replace-fail \
      'cp -r "$base/vol/output/." "$tmp/output"' 'kill -KILL $$'
    chmod +x "$out"
  '';
  VERIFY = lib.getExe runtime.tools.verify;
  PROMOTE = lib.getExe runtime.tools.promote;
  env = pkgsU.buildEnv { name = "agent-runtime-coder-env"; paths = tpl.packages; };
  run = lib.getExe (builtins.head tpl.packages);
  repo = tpl.repositories.rf-proto.path;
  sh = pkgs.writeShellScript;

  # what the instance holds: the real binary (offline --version), the named skill, the pinned source,
  # a private HOME, no credential and no network
  probe = sh "coder-probe" ''
    set -u
    fail=0
    chk() { if "$@"; then echo "ok   $*"; else echo "FAIL $*"; fail=1; fi; }
    echo "claude_version: $(timeout 30 claude --version 2>&1 | head -1)"
    chk test -f /skills/rust-engineering/SKILL.md
    chk test -f ${repo}/Cargo.toml
    chk test -w "$HOME"
    chk test ! -e /run/agent-runtime/credentials
    chk test "$(ls /sys/class/net)" = lo
    chk test "$(id -u)" != 0
    exit $fail
  '';
  # the real binary asked to work without a harness credential: it must refuse, not hang or edit
  realNoAuth = sh "coder-real-no-auth" ''
    cd ${repo}
    rc=0
    timeout 60 claude -p "Add a doc comment to src/lib.rs" --output-format json \
      --permission-mode acceptEdits --allowedTools Read,Edit >"$AGENT_RUNTIME_OUTPUT/claude.json" 2>"$AGENT_RUNTIME_OUTPUT/claude.err" || rc=$?
    echo "claude_exit=$rc"
    exit "$rc"
  '';
  # MODEL-FREE fixture, labelled as such: a deterministic edit plus the project's tests, so the export,
  # verification and promotion path is exercised with a nonempty patch. Not the real-agent acceptance.
  fixtureEdit = sh "coder-fixture-edit" ''
    set -eu
    export CARGO_HOME=${tpl.filesystem.cache.path}/cargo CARGO_TARGET_DIR=${tpl.filesystem.cache.path}/target CARGO_NET_OFFLINE=true
    cd ${repo}
    cat >>src/lib.rs <<'RS'

/// #169 fixture edit: the sum of two bytes, saturating at 255.
pub fn saturating_byte_sum(a: u8, b: u8) -> u8 {
    a.saturating_add(b)
}

#[cfg(test)]
mod fixture_169 {
    #[test]
    fn saturates() {
        assert_eq!(super::saturating_byte_sum(250, 10), 255);
        assert_eq!(super::saturating_byte_sum(1, 2), 3);
    }
}
RS
    cargo test --offline --locked >"$AGENT_RUNTIME_OUTPUT/cargo-test.log" 2>&1
    printf '{"agent":"model-free-fixture","exit":0}\n' >"$AGENT_RUNTIME_OUTPUT/result.json"
    grep -c 'test result: ok' "$AGENT_RUNTIME_OUTPUT/cargo-test.log"
  '';
  # a payload that leaks the delivered token into a tracked file: the export must refuse the patch
  plantLeak = sh "coder-plant-leak" ''
    set -eu
    cd ${repo}
    printf '// %s\n' "$(cat /run/agent-runtime/credentials/token)" >>src/lib.rs
  '';
  # recompute a bundle's digests after a test edits it, so the verifier's later checks are reached
  reseal = sh "reseal" ''
    set -eu
    b=$1
    for r in "$b"/sources/*.json; do
      n=$(basename "$r" .json); [ "$n" != export ] || continue
      p="$b/sources/$(jq -r .patch "$r")"; [ -f "$p" ] || continue
      jq --arg s "$(sha256sum "$p" | cut -d' ' -f1)" '.patchSha256 = $s' "$r" >"$r.t" && mv "$r.t" "$r"
    done
    files=$(cd "$b" && find . -type f ! -name bundle.json -printf '%P\n' | sort | while read -r f; do
      jq -nc --arg f "$f" --arg s "$(sha256sum "$f" | cut -d' ' -f1)" --argjson y "$(stat -c %s "$f")" '{path: $f, sha256: $s, bytes: $y}'
    done | jq -sc .)
    jq --argjson f "$files" '.files = $f' "$b/bundle.json" >"$b/bundle.json.t" && mv "$b/bundle.json.t" "$b/bundle.json"
  '';
in
pkgs.testers.runNixOSTest {
  name = "agent-runtime-coder";
  nodes.machine = {
    virtualisation.memorySize = 4096;
    virtualisation.cores = 2;
    virtualisation.diskSize = 6144;
    boot.kernel.sysctl."vm.panic_on_oom" = 0;
    networking.dhcpcd.denyInterfaces = [ "ve-*" ];
    virtualisation.additionalPaths = [ rfProto skills env evaluated.manifestDir ];
    environment.systemPackages = with pkgs; [ util-linux procps gnugrep gawk coreutils jq git findutils ];
    nix.settings.experimental-features = [ "nix-command" ];
  };
  testScript = ''
    import json
    M = "${manifest}"
    POLICY = "${evaluated.hostPolicy}"
    V = "/var/lib/agent-runtime"
    E = f"{V}/exports"
    TASK = "sammasak/nixos-config#169"

    def st(i):
        return json.loads(machine.succeed(f"${I} status {i}"))

    def run(i, prog, flags=""):
        machine.succeed(f"${I} create {i} --template {M} --host {POLICY} --task {TASK}")
        machine.execute(f"${I} start {i} {flags} --wait -- {prog}")
        s = st(i)
        print(f"== {i}: {s['state']}", json.dumps(s.get("result")))
        return s

    def done(i, flags="--discard"):
        machine.succeed(f"${I} destroy {i} {flags}")
        machine.succeed(f"! findmnt -rn | grep -qE 'agent-runtime[-/]{i}(/| |$)'")
        machine.succeed(f"! systemctl list-units --all --no-legend 'agent-runtime-{i}.service' | grep -q .")
        machine.succeed(f"test ! -e {V}/{i} -a ! -e /run/agent-runtime/{i}")

    def verify(b, flags=""):
        rc, out = machine.execute(f"${VERIFY} --bundle {b} --template {M} {flags} 2>&1")
        print(f"verify {b} {flags}: rc={rc}", out.strip()[-400:])
        return rc, out

    def refused(b, code, text, flags=""):
        rc, out = verify(b, flags)
        assert rc == code and text in out, (b, rc, out)

    machine.wait_for_unit("multi-user.target")
    machine.succeed("systemd-run --unit=host-sentinel --property=Type=exec sleep 3600")
    # a dummy subscription token in the shape of the SOPS claude_oauth_token, nothing real
    machine.succeed("printf 'sk-ant-oat01-DUMMY-not-a-token-169' > /root/dummy-token && chmod 600 /root/dummy-token")

    with subtest("the instance holds the real binary, the skill and the pinned source; no credential, no network"):
        s = run("probe", "${probe}")
        out = machine.succeed("${I} logs probe")
        print(out)
        assert s["state"] == "succeeded" and "FAIL" not in out, out
        assert "Claude Code" in out, out
        assert s["template"]["digests"]["template"] == "${evaluated.manifestData.claude-coder.digests.template}"
        done("probe")

    with subtest("the real Claude Code without a harness credential refuses, edits nothing"):
        s = run("noauth", "${realNoAuth}")
        assert s["state"] == "failed" and s["result"]["exitStatus"] == 1, s
        machine.succeed("${I} export noauth")
        c = json.loads(machine.succeed(f"cat {E}/noauth.runs/latest/output/claude.json"))
        print("claude -p without auth:", json.dumps({k: c.get(k) for k in ("is_error", "terminal_reason", "result", "total_cost_usd")}))
        assert c["is_error"] and c["terminal_reason"] == "api_error" and "Not logged in" in c["result"] and c["total_cost_usd"] == 0, c
        assert machine.succeed(f"cat {E}/noauth.runs/latest/sources/rf-proto.patch") == "", "an edit without auth"
        verify(f"{E}/noauth.runs/latest")  # an empty patch verifies; it is refused only when a change is required
        refused(f"{E}/noauth.runs", 9, "empty patch", "--require-change")  # the runs dir resolves to its latest (#184)
        done("noauth", "")

    with subtest("the runner fails closed without a credential: the model is never called"):
        s = run("closed", "${run} 'add a function'")
        assert s["state"] == "failed" and s["result"]["exitStatus"] == 77, s
        machine.succeed("${I} export closed")
        r = json.loads(machine.succeed(f"cat {E}/closed.runs/latest/output/result.json"))
        assert r["auth"] == "missing" and r["exit"] == 77, r
        machine.succeed(f"test ! -e {E}/closed.runs/latest/output/claude.json")
        done("closed", "")

    with subtest("with the token but no egress the run is bounded, edits nothing and never leaks the token"):
        s = run("noegress", "${run} --turn-seconds 20 'add a function'", "--credential /root/dummy-token")
        assert s["state"] == "failed" and s["result"]["exitStatus"] != 0, s
        # the run's tmpfs copy gone (as after a reboot): the export fails closed, then takes the re-passed token
        machine.succeed("rm -f /run/agent-runtime/noegress/cred/token")
        rc, out = machine.execute("${I} export noegress 2>&1")
        print("export without the token copy:", rc, out.strip()[-300:])
        assert rc == 5 and "copy is gone" in out, (rc, out)
        machine.succeed("${I} export noegress --credential /root/dummy-token")
        r = json.loads(machine.succeed(f"cat {E}/noegress.runs/latest/output/result.json"))
        assert r["auth"] == "oauth-token" and r["claudeExit"] != 0 and r["testsExit"] == 0, r
        machine.succeed(f"! grep -rqF DUMMY-not-a-token {E}/noegress.runs")
        machine.succeed("! journalctl --no-pager | grep -qF DUMMY-not-a-token")
        patch = machine.succeed(f"cat {E}/noegress.runs/latest/sources/rf-proto.patch")
        assert patch == "", patch[:1500]
        done("noegress", "")

    with subtest("a token planted in a tracked file refuses the export: the patch is scanned too"):
        s = run("leak", "${plantLeak}", "--credential /root/dummy-token")
        assert s["state"] == "succeeded", s
        rc, out = machine.execute("${I} export leak 2>&1")
        print("export of a patch carrying the token:", rc, out.strip()[-300:])
        assert rc == 5 and "source patch" in out, (rc, out)
        machine.succeed(f"test ! -e {E}/leak.runs/latest")
        machine.succeed(f"test -z \"$(ls -A {E}/leak.runs 2>/dev/null | grep -v '^\\.tmp\\.' || true)\"")
        # a retry is refused the same way: the refused export put the source back as pending, not dropped the patch
        rc, out = machine.execute("${I} export leak 2>&1")
        assert rc == 5 and "source patch" in out, (rc, out)
        done("leak", "--discard")

    with subtest("MODEL-FREE fixture edit: a nonempty patch the host verifies against the pinned revision"):
        s = run("edit", "${fixtureEdit}")
        assert s["state"] == "succeeded", s
        machine.succeed("${I} export edit")
        EDIT = st("edit")["export"]["dir"]  # the run's own bundle, exports/edit.runs/<runId> (#184)
        rc, out = verify(EDIT, "--require-change")
        assert rc == 0, out
        v = json.loads(out)
        src = v["sources"]["rf-proto"]
        assert v["kind"] == "agent-runtime-verified" and src["changedPaths"] == ["src/lib.rs"] and src["patchBytes"] > 0, v
        assert src["base"]["rev"] == "${rfProto.rev}", src
        assert "test result: ok" in machine.succeed(f"cat {EDIT}/output/cargo-test.log")
        print("VERIFIED", json.dumps(v))

        # PROMOTION (#169 acceptance 3): the trusted host applies the VERIFIED patch onto a clean checkout
        # at the pinned base, commits it on a branch, and records the commit sha + bundle digest -- no push,
        # no gh, no token. The checkout is the pinned source content as a local git repo.
        machine.succeed("rm -rf /tmp/wt && cp -rp ${rfProto} /tmp/wt && chmod -R u+w /tmp/wt")
        # add -A -f to mirror the verifier's tree_of (force, ignoring .gitignore), so the base tree matches
        machine.succeed("git -C /tmp/wt init -q && git -C /tmp/wt add -A -f && git -C /tmp/wt -c user.name=t -c user.email=t@t commit -q -m base")
        out = machine.succeed(f"${PROMOTE} --bundle {EDIT} --template {M} --into /tmp/wt --branch promote-169")
        p = json.loads(out)
        assert p["kind"] == "agent-runtime-promoted" and p["source"] == "rf-proto", p
        assert p["pushed"] is False and p["changedPaths"] == ["src/lib.rs"] and p["bundleSha256"], p
        # the promoted branch holds exactly the verified artifact: its tree is the verifier's tree
        assert machine.succeed("git -C /tmp/wt rev-parse --abbrev-ref HEAD").strip() == "promote-169"
        assert machine.succeed("git -C /tmp/wt rev-parse 'HEAD^{tree}'").strip() == p["tree"] == src["tree"], p
        assert machine.succeed("git -C /tmp/wt show HEAD:src/lib.rs") != machine.succeed("git -C /tmp/wt show HEAD~1:src/lib.rs"), "the promoted file must differ from the base"
        assert "No GitHub token entered the runtime" in machine.succeed("git -C /tmp/wt log -1 --format=%B")
        # promote refuses an UNVERIFIED (tampered) bundle: verify runs first, the worktree is untouched
        machine.succeed(f"rm -rf /tmp/tb && cp -r {EDIT} /tmp/tb && printf x >> /tmp/tb/sources/rf-proto.patch")
        rc, out = machine.execute(f"${PROMOTE} --bundle /tmp/tb --template {M} --into /tmp/wt --branch nope 2>&1")
        assert rc == 9 and "sha256" in out, (rc, out)
        machine.succeed("! git -C /tmp/wt rev-parse --verify nope 2>/dev/null")
        machine.succeed("rm -rf /tmp/wt /tmp/tb")
        done("edit", "")

    with subtest("a repeated instance id keeps every run's bundle: both intact, latest the newest, verify and promote both"):
        def runs(i):  # the run directories under exports/<id>.runs (not latest, not a staging dir)
            return sorted(x for x in machine.succeed(f"ls -A {E}/{i}.runs").split() if x != "latest" and not x.startswith("."))

        def digest(b):
            return machine.succeed(f"cd {b} && find . -type f -print0 | sort -z | xargs -0 sha256sum")

        def promote(b, branch):
            machine.succeed("rm -rf /tmp/wt && cp -rp ${rfProto} /tmp/wt && chmod -R u+w /tmp/wt")
            machine.succeed("git -C /tmp/wt init -q && git -C /tmp/wt add -A -f && git -C /tmp/wt -c user.name=t -c user.email=t@t commit -q -m base")
            p = json.loads(machine.succeed(f"${PROMOTE} --bundle {b} --template {M} --into /tmp/wt --branch {branch}"))
            assert p["kind"] == "agent-runtime-promoted" and p["changedPaths"] == ["src/lib.rs"], p
            assert machine.succeed("git -C /tmp/wt rev-parse 'HEAD^{tree}'").strip() == p["tree"], p
            machine.succeed("rm -rf /tmp/wt")
            return p

        # run A: create, run, export, destroy
        assert run("again", "${fixtureEdit}")["state"] == "succeeded"
        machine.succeed("${I} export again")
        a = st("again")["export"]
        A, ra = a["dir"], a["runId"]
        assert A == f"{E}/again.runs/{ra}" and len(ra) == 32, a
        # the same instance exported again: the same bundle, never a second
        machine.succeed("${I} export again")
        assert st("again")["export"] == a and runs("again") == [ra], (st("again")["export"], runs("again"))
        before = digest(A)
        done("again", "")
        # An old flat bundle can coexist with the new layout, without the new metadata fields.
        legacy = f"{E}/again"
        machine.succeed(f"cp -rp {A} {legacy} && jq 'del(.runId, .invocation)' {legacy}/bundle.json > /tmp/legacy-bundle.json && mv /tmp/legacy-bundle.json {legacy}/bundle.json")
        legacy_before = digest(legacy)
        # run B: the same id again
        assert run("again", "${fixtureEdit}")["state"] == "succeeded"
        machine.succeed("${I} export again")
        b = st("again")["export"]
        B, rb = b["dir"], b["runId"]
        assert rb != ra and B == f"{E}/again.runs/{rb}" and runs("again") == sorted([ra, rb]), (a, b, runs("again"))
        assert digest(A) == before, "run A's bundle changed when run B exported"
        assert machine.succeed(f"readlink {E}/again.runs/latest").strip() == rb
        for d, r in [(A, ra), (B, rb)]:
            bj = json.loads(machine.succeed(f"cat {d}/bundle.json"))
            assert bj["runId"] == r and bj["id"] == "again" and bj["invocation"], bj
        # each verifies against its own source, by its path, through latest, and through the runs dir
        trees = {}
        for d in [A, B, f"{E}/again.runs/latest", f"{E}/again.runs", legacy]:
            rc, out = verify(d, "--require-change")
            assert rc == 0, (d, out)
            trees[d] = json.loads(out)["sources"]["rf-proto"]["tree"]
        assert len(set(trees.values())) == 1, trees  # the same fixture edit: one tree, from each bundle
        assert promote(A, "promote-a")["bundleSha256"] != promote(B, "promote-b")["bundleSha256"]
        assert promote(legacy, "promote-legacy")["tree"] == trees[legacy]
        assert promote(f"{E}/again.runs/latest", "promote-latest")["tree"] == trees[B]
        assert promote(f"{E}/again.runs", "promote-runs")["tree"] == trees[B]
        # an export interrupted after its publish but before its record: the retry adopts the published bundle
        machine.succeed(f"rm {V}/again/exported.json")
        # A damaged published bundle is kept and refused, without blessing it via exported.json.
        patch = f"{B}/sources/rf-proto.patch"
        machine.succeed(f"cp {patch} /tmp/intact.patch && printf x >> {patch}")
        damaged = digest(B)
        rc, out = machine.execute("${I} export again 2>&1")
        assert rc == 12 and "is kept, not replaced" in out, (rc, out)
        machine.succeed(f"test ! -e {V}/again/exported.json")
        assert digest(B) == damaged, "refused adoption must preserve the damaged evidence"
        machine.succeed(f"cp /tmp/intact.patch {patch}")
        machine.succeed("${I} export again")
        assert st("again")["export"]["dir"] == B and runs("again") == sorted([ra, rb]), st("again")["export"]
        assert machine.succeed(f"readlink {E}/again.runs/latest").strip() == rb
        done("again", "")
        assert digest(A) == before and runs("again") == sorted([ra, rb]), "destroy must keep every bundle"
        assert digest(legacy) == legacy_before, "the legacy flat bundle must stay unchanged"

    with subtest("an instance created before runId support persists its identity across export recovery"):
        assert run("legacy-instance", "${fixtureEdit}")["state"] == "succeeded"
        record = f"{V}/legacy-instance/instance.json"
        machine.succeed(f"jq 'del(.runId)' {record} > /tmp/legacy-instance.json && mv /tmp/legacy-instance.json {record}")
        machine.succeed("${I} export legacy-instance")
        original = st("legacy-instance")["export"]
        rid = original["runId"]
        assert len(rid) == 32 and machine.succeed(f"cat {V}/legacy-instance/run-id").strip() == rid, original
        rc, out = verify(original["dir"], "--require-change")
        assert rc == 0, out
        machine.succeed(f"rm {V}/legacy-instance/exported.json")
        machine.succeed("${I} reconcile && ${I} export legacy-instance")
        assert st("legacy-instance")["export"]["dir"] == original["dir"]
        assert st("legacy-instance")["export"]["runId"] == rid
        done("legacy-instance", "")

    with subtest("SIGKILL after the source export preserves the patch on retry, including after reconciliation"):
        assert run("interrupted", "${fixtureEdit}")["state"] == "succeeded"
        rc, out = machine.execute("${interruptedExport} export interrupted 2>&1")
        assert rc == 137, (rc, out)
        ws = f"{V}/interrupted/vol/workspace"
        machine.succeed(f"test ! -e {ws}/export-pending -a -f {ws}/exported.json")
        machine.succeed(f"test ! -e {V}/interrupted/exported.json -a ! -e {E}/interrupted.runs/latest")
        rc, out = machine.execute("${I} destroy interrupted 2>&1")
        assert rc == 12 and "has not been exported" in out, (rc, out)
        machine.succeed("${I} reconcile")
        machine.succeed("${I} export interrupted")
        b = st("interrupted")["export"]["dir"]
        rc, out = verify(b, "--require-change")
        assert rc == 0, out
        assert json.loads(out)["sources"]["rf-proto"]["changedPaths"] == ["src/lib.rs"], out
        original = st("interrupted")["export"]
        machine.succeed("${I} export interrupted")
        assert st("interrupted")["export"] == original
        done("interrupted", "")

    with subtest("a foreign directory at a run's bundle path is kept and refused, never replaced"):
        assert run("clash", "${fixtureEdit}")["state"] == "succeeded"
        rc_ = st("clash")["runId"]
        machine.succeed(f"mkdir -p {E}/clash.runs/{rc_} && echo planted > {E}/clash.runs/{rc_}/note")
        rc, out = machine.execute("${I} export clash 2>&1")
        assert rc == 12 and "is kept, not replaced" in out, (rc, out)
        assert machine.succeed(f"cat {E}/clash.runs/{rc_}/note").strip() == "planted"
        machine.succeed(f"test ! -e {V}/clash/exported.json -a ! -e {E}/clash.runs/latest")
        # the planted directory moved aside by the operator, the export completes
        machine.succeed(f"mv {E}/clash.runs/{rc_} /tmp/clash-aside")
        machine.succeed("${I} export clash")
        assert st("clash")["export"]["dir"] == f"{E}/clash.runs/{rc_}"
        done("clash", "")

    with subtest("the verifier refuses a tampered, incomplete, unlisted, escaping, oversized, malformed, foreign or mispinned bundle"):
        def copy(name):
            machine.succeed(f"rm -rf /tmp/{name} && cp -r {EDIT} /tmp/{name}")
            return f"/tmp/{name}"
        b = copy("tampered"); machine.succeed(f"printf x >> {b}/sources/rf-proto.patch")
        refused(b, 9, "does not match its sha256 in bundle.json")
        b = copy("nobundle"); machine.succeed(f"rm {b}/bundle.json")
        refused(b, 9, "has no bundle.json")
        b = copy("interrupted"); machine.succeed(f"rm {b}/sources/export.json && ${reseal} {b}")
        refused(b, 9, "interrupted")
        b = copy("dotgit")
        machine.succeed(f"printf 'diff --git a/.git/config b/.git/config\\nnew file mode 100644\\n--- /dev/null\\n+++ b/.git/config\\n@@ -0,0 +1 @@\\n+x\\n' > {b}/sources/rf-proto.patch && ${reseal} {b}")
        refused(b, 9, "the repository's .git")
        b = copy("escape")
        machine.succeed(f"printf 'diff --git a/../escape b/../escape\\nnew file mode 100644\\n--- /dev/null\\n+++ b/../escape\\n@@ -0,0 +1 @@\\n+x\\n' > {b}/sources/rf-proto.patch && ${reseal} {b}")
        rc, out = verify(b)
        # git itself may refuse to parse the path (malformed) or report it (outside): refused either way
        assert rc == 9 and ("outside the repository" in out or "malformed" in out), (rc, out)
        b = copy("oversized")
        refused(b, 7, "over the 64-byte cap", "--max-patch-bytes 64")
        b = copy("malformed"); machine.succeed(f"printf 'not a patch\\n' > {b}/sources/rf-proto.patch && ${reseal} {b}")
        refused(b, 9, "malformed")
        b = copy("foreign")
        machine.succeed(f"printf 'diff --git a/src/lib.rs b/src/lib.rs\\n--- a/src/lib.rs\\n+++ b/src/lib.rs\\n@@ -1,1 +1,1 @@\\n-this line is not in the pinned file\\n+x\\n' > {b}/sources/rf-proto.patch && ${reseal} {b}")
        refused(b, 9, "does not apply to the pinned base")
        b = copy("pathlie")
        machine.succeed(f"jq '.changedPaths = [\"README.md\"]' {b}/sources/rf-proto.json > {b}/t && mv {b}/t {b}/sources/rf-proto.json && ${reseal} {b}")
        refused(b, 9, "the record says")
        b = copy("emptyfiles"); machine.succeed(f"jq '.files = []' {b}/bundle.json > {b}/t && mv {b}/t {b}/bundle.json")
        refused(b, 9, "lists no files")
        b = copy("unlisted"); machine.succeed(f"printf x > {b}/output/extra")
        refused(b, 9, "does not list")
        b = copy("omitted"); machine.succeed(f"jq '.omittedPatches = [{{\"patch\": \"rf-proto.patch\", \"bytes\": 99999999}}]' {b}/bundle.json > {b}/t && mv {b}/t {b}/bundle.json && ${reseal} {b}")
        refused(b, 9, "omitted at export")
        b = copy("pinlie"); machine.succeed(f"jq '.base.rev = \"{'0' * 40}\"' {b}/sources/rf-proto.json > {b}/t && mv {b}/t {b}/sources/rf-proto.json && ${reseal} {b}")
        refused(b, 9, "does not match the template's pin")
        b = copy("notinstore"); machine.succeed(f"jq '.base.storePath = \"/nix/store/{'a' * 32}-source\"' {b}/sources/rf-proto.json > {b}/t && mv {b}/t {b}/sources/rf-proto.json && ${reseal} {b}")
        refused(b, 8, "not in this host's store")
        b = copy("wrongnar"); machine.succeed(f"jq '.base.storePath = \"${skills}\"' {b}/sources/rf-proto.json > {b}/t && mv {b}/t {b}/sources/rf-proto.json && ${reseal} {b}")
        refused(b, 8, "has narHash")
        b = copy("difftree"); machine.succeed(f"jq '.tree = \"{'0' * 40}\"' {b}/sources/rf-proto.json > {b}/t && mv {b}/t {b}/sources/rf-proto.json && ${reseal} {b}")
        refused(b, 9, "the patched base is tree")
        b = copy("droprecord"); machine.succeed(f"rm {b}/sources/rf-proto.json {b}/sources/rf-proto.patch && ${reseal} {b}")
        refused(b, 9, "has no record of it")

    with subtest("cancellation: a hanging agent run stops as cancelled, exports a recovery bundle, leaves nothing"):
        machine.succeed(f"${I} create hang --template {M} --host {POLICY} --task {TASK}")
        machine.succeed("${I} start hang --credential /root/dummy-token -- ${run} --turn-seconds 600 'add a function'")
        machine.wait_until_succeeds("${I} status hang | jq -e '.state == \"running\"'", timeout=60)
        machine.succeed("${I} cancel hang")
        machine.wait_until_succeeds("${I} status hang | jq -e '.state == \"cancelled\"'", timeout=60)
        machine.succeed("${I} export hang")
        hang = st("hang")["export"]["dir"]
        assert json.loads(machine.succeed(f"cat {hang}/bundle.json"))["recovery"]
        machine.succeed(f"! grep -rqF DUMMY-not-a-token {E}/hang.runs")
        rc, out = verify(hang)
        assert rc == 0, out
        done("hang", "")

    with subtest("the host is unaffected: its own service runs, no runtime state is left"):
        machine.succeed("systemctl is-active host-sentinel.service")
        machine.succeed(f"test -z \"$(ls -A {V} | grep -v '^exports$')\"")
        machine.succeed("! systemctl list-units --all --no-legend 'agent-runtime-*' | grep -q .")
        machine.succeed("! findmnt -rn | grep -q agent-runtime")
  '';
}
