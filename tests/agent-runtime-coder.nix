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
  VERIFY = lib.getExe runtime.tools.verify;
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
        c = json.loads(machine.succeed(f"cat {E}/noauth/output/claude.json"))
        print("claude -p without auth:", json.dumps({k: c.get(k) for k in ("is_error", "terminal_reason", "result", "total_cost_usd")}))
        assert c["is_error"] and c["terminal_reason"] == "api_error" and "Not logged in" in c["result"] and c["total_cost_usd"] == 0, c
        assert machine.succeed(f"cat {E}/noauth/sources/rf-proto.patch") == "", "an edit without auth"
        verify(f"{E}/noauth")  # an empty patch verifies; it is refused only when a change is required
        refused(f"{E}/noauth", 9, "empty patch", "--require-change")
        done("noauth", "")

    with subtest("the runner fails closed without a credential: the model is never called"):
        s = run("closed", "${run} 'add a function'")
        assert s["state"] == "failed" and s["result"]["exitStatus"] == 77, s
        machine.succeed("${I} export closed")
        r = json.loads(machine.succeed(f"cat {E}/closed/output/result.json"))
        assert r["auth"] == "missing" and r["exit"] == 77, r
        machine.succeed(f"test ! -e {E}/closed/output/claude.json")
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
        r = json.loads(machine.succeed(f"cat {E}/noegress/output/result.json"))
        assert r["auth"] == "oauth-token" and r["claudeExit"] != 0 and r["testsExit"] == 0, r
        machine.succeed(f"! grep -rqF DUMMY-not-a-token {E}/noegress")
        machine.succeed("! journalctl --no-pager | grep -qF DUMMY-not-a-token")
        patch = machine.succeed(f"cat {E}/noegress/sources/rf-proto.patch")
        assert patch == "", patch[:1500]
        done("noegress", "")

    with subtest("a token planted in a tracked file refuses the export: the patch is scanned too"):
        s = run("leak", "${plantLeak}", "--credential /root/dummy-token")
        assert s["state"] == "succeeded", s
        rc, out = machine.execute("${I} export leak 2>&1")
        print("export of a patch carrying the token:", rc, out.strip()[-300:])
        assert rc == 5 and "source patch" in out, (rc, out)
        machine.succeed(f"test ! -e {E}/leak")
        # a retry is refused the same way: the refused export put the source back as pending, not dropped the patch
        rc, out = machine.execute("${I} export leak 2>&1")
        assert rc == 5 and "source patch" in out, (rc, out)
        done("leak", "--discard")

    with subtest("MODEL-FREE fixture edit: a nonempty patch the host verifies against the pinned revision"):
        s = run("edit", "${fixtureEdit}")
        assert s["state"] == "succeeded", s
        machine.succeed("${I} export edit")
        rc, out = verify(f"{E}/edit", "--require-change")
        assert rc == 0, out
        v = json.loads(out)
        src = v["sources"]["rf-proto"]
        assert v["kind"] == "agent-runtime-verified" and src["changedPaths"] == ["src/lib.rs"] and src["patchBytes"] > 0, v
        assert src["base"]["rev"] == "${rfProto.rev}", src
        assert "test result: ok" in machine.succeed(f"cat {E}/edit/output/cargo-test.log")
        print("VERIFIED", json.dumps(v))
        done("edit", "")

    with subtest("the verifier refuses a tampered, incomplete, unlisted, escaping, oversized, malformed, foreign or mispinned bundle"):
        def copy(name):
            machine.succeed(f"rm -rf /tmp/{name} && cp -r {E}/edit /tmp/{name}")
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
        assert json.loads(machine.succeed(f"cat {E}/hang/bundle.json"))["recovery"]
        machine.succeed(f"! grep -rqF DUMMY-not-a-token {E}/hang")
        rc, out = verify(f"{E}/hang")
        assert rc == 0, out
        done("hang", "")

    with subtest("the host is unaffected: its own service runs, no runtime state is left"):
        machine.succeed("systemctl is-active host-sentinel.service")
        machine.succeed(f"test -z \"$(ls -A {V} | grep -v '^exports$')\"")
        machine.succeed("! systemctl list-units --all --no-legend 'agent-runtime-*' | grep -q .")
        machine.succeed("! findmnt -rn | grep -q agent-runtime")
  '';
}
