# Exercise the published Factum #38 execution request inside the existing nspawn lifecycle.
{ pkgs, lib, skills, factumEnvJsonPath, factumProfilePath, factumRequestPath }:
let
  requestPath = builtins.storePath factumRequestPath;
  request = builtins.fromJSON (builtins.readFile requestPath);
  capturedRustVersion =
    let rustTools = builtins.filter (tool: tool.name == "rust") (request.tools or [ ]);
    in if builtins.length rustTools == 1 then (builtins.head rustTools).version else
      throw "Factum execution request must contain exactly one captured Rust version";
  envJson = builtins.storePath factumEnvJsonPath;
  profile = builtins.storePath factumProfilePath;
  source = builtins.fetchTree {
    type = "git";
    url = "https://github.com/sammasak/factum";
    rev = "0caf25dbb2ae9bc37bcc208b20a7b9ba0b551780";
  };
  project = builtins.storePath (toString source);
  vendor = pkgs.rustPlatform.importCargoLock { lockFile = "${project}/Cargo.lock"; };
  env = builtins.fromJSON (builtins.readFile envJson);
  validStorePath = path:
    builtins.match "/nix/store/[0-9abcdfghijklmnpqrsvwxyz]{32}-[^ /:\t\n]+" path != null
    && builtins.pathExists path;
  before = delimiter: value: builtins.head (lib.splitString delimiter value);
  storeBase = part: before "'" (before "\"" (before " " (before "/" (before ":" part))));
  storeRefs = value:
    if !builtins.isString value then [ ] else
    map builtins.storePath (lib.filter validStorePath (map (part: "/nix/store/${storeBase part}")
      (lib.drop 1 (lib.splitString "/nix/store/" value))));
  envStoreRefs = lib.unique (lib.concatMap
    (variable: if variable.type == "exported" then storeRefs variable.value else [ ])
    (builtins.attrValues env.variables));
  profileBootstrap = pkgs.runCommand "factum-devenv-runtime-tools" { } ''
    mkdir -p "$out/bin"
    ln -s ${pkgs.git}/bin/git "$out/bin/git"
    ln -s ${profile} "$out/devenv-profile"
  '';
  expectedRequest = {
    repo = "sammasak/factum";
    sha = "0caf25dbb2ae9bc37bcc208b20a7b9ba0b551780";
    root = ".";
    environment_index = 0;
    target_system = "x86_64-linux";
    lockfile = "devenv.lock";
  };
  envClosure = pkgs.runCommand "factum-devenv-exported-store-closure" { } ''
    mkdir -p "$out"
    printf '%s\n' ${lib.escapeShellArgs envStoreRefs} > "$out/references"
  '';
  cargoHook = ''
    export CARGO_HOME=/var/cache/agent/cargo
    export CARGO_NET_OFFLINE=true
    export CARGO_BUILD_JOBS=1
    # Cargo's default test debuginfo writes over 17 GiB through the bounded
    # loop-backed workspace volume during the full Factum suite. Its charged
    # page cache alone exceeded the 8 GiB runtime budget in the acceptance VM.
    export CARGO_PROFILE_TEST_DEBUG=0
    mkdir -p "$CARGO_HOME"
    cat >"$CARGO_HOME/config.toml" <<'CARGO_CONFIG'
    [source.crates-io]
    replace-with = "vendored-sources"
    [source.vendored-sources]
    directory = "${vendor}"
    [net]
    offline = true
    CARGO_CONFIG
  '';
  projectedEnv = pkgs.runCommand "factum-devenv-projected-env.json" { nativeBuildInputs = [ pkgs.jq ]; } ''
    ${pkgs.jq}/bin/jq --arg hook ${lib.escapeShellArg cargoHook} \
      --arg gitBin ${lib.escapeShellArg "${pkgs.git}/bin"} '
      .variables.PATH.value = ($gitBin + ":" + .variables.PATH.value)
      | .variables.CARGO_HOME = { type: "exported", value: "/var/cache/agent/cargo" }
      | .variables.CARGO_NET_OFFLINE = { type: "exported", value: "true" }
      | .variables.CARGO_BUILD_JOBS = { type: "exported", value: "1" }
      | .variables.CARGO_PROFILE_TEST_DEBUG = { type: "exported", value: "0" }
      | .variables.shellHook.value += ("\n" + $hook)
    ' ${envJson} > "$out"
  '';
  failureRequest = request // {
    check = request.check // {
      argv = [ "cargo" "test" "--locked" "--test" "agent_runtime_missing_acceptance_target" ];
      evidence = [ ];
      index = null;
      selection = "explicit";
    };
  };
  failureRequestJson = pkgs.writeText "factum-failure-injection-request.json" (builtins.toJSON failureRequest);
  brokenSourceRequest = request // {
    check = request.check // {
      argv = [ "bash" "-c" "cargo --version && printf '\\npub fn broken( {\\n' >> src/lib.rs && cargo --version && cargo fmt --all --check" ];
      evidence = [ ];
      index = null;
      selection = "explicit";
    };
  };
  brokenSourceRequestJson = pkgs.writeText "factum-broken-source-request.json" (builtins.toJSON brokenSourceRequest);
  fixtureNar = lib.fileContents (pkgs.runCommand "factum-devenv-narhash" { nativeBuildInputs = [ pkgs.nix ]; } ''
    nix --extra-experimental-features nix-command hash path ${project} > "$out"
  '');
  runtime = import ../modules/agent-runtime/lib.nix { inherit lib pkgs; };
  runnerModule = import ../modules/agent-runtime/devenv-projection.nix { inherit lib pkgs; } {
    envJson = projectedEnv;
    inherit profile;
    projectRoot = "/workspace/factum";
    consumeRequest = true;
    inherit expectedRequest;
  };
  I = lib.getExe runtime.tools.instance;
  VERIFY = lib.getExe runtime.tools.verify;
  runner = lib.getExe runnerModule.runner;
  manifestData = runtime.evalManifests {
    modules = [
      {
        sam.agentRuntime.host = {
          enable = true;
          eligibleTemplates = [ "factum-devenv" ];
          maxConcurrentInstances = 1;
          reserve = { memoryMiB = 512; diskMiB = 1024; };
        };
        sam.agentRuntime.templates.factum-devenv = {
          role = { name = "factum-devenv"; harness = "codex"; };
          repositories.factum = {
            github = "sammasak/factum";
            ref = { type = "commit"; value = expectedRequest.sha; };
            lock = { rev = expectedRequest.sha; narHash = fixtureNar; outPath = "${project}"; };
            path = "/workspace/factum";
            writable = true;
          };
          skillsSource = skills;
          packages = [ runnerModule.runner profileBootstrap envClosure ];
          filesystem = {
            # Factum's nested test-plan cases each create Cargo targets under target/tmp;
            # a 16 GiB workspace filled before the complete `cargo test --locked` finished.
            workspaceBudget = { sizeMiB = 65536; inodes = 1200000; };
            home = { sizeMiB = 64; inodes = 4000; };
            tmp = { sizeMiB = 1024; inodes = 50000; };
            cache = { sizeMiB = 2048; inodes = 50000; };
            output = { sizeMiB = 64; inodes = 4000; };
          };
          resources = { cpus = 2; memoryMiB = 8192; tasksMax = 1024; timeoutMinutes = 45; };
        };
      }
    ];
  };
  manifest = "${manifestData.manifestDir}/factum-devenv.json";
  template = manifestData.manifestData.factum-devenv;
in
assert request.status == "ready" && request.blockers == [ ];
assert request.source.sha == expectedRequest.sha && request.source.repo == expectedRequest.repo;
assert builtins.isString capturedRustVersion && builtins.stringLength capturedRustVersion > 0;
assert request.check.argv == [ "cargo" "test" "--locked" ];
assert template.policies.network == { egress = "none"; allow = [ ]; };
assert template.policies.capabilities == [ ] && template.policies.privateSources == [ ];
assert template.sources.factum.ref.value == expectedRequest.sha;
assert template.filesystem.workspaceBudget.sizeMiB == 65536 && template.filesystem.cache.sizeMiB == 2048;
pkgs.testers.runNixOSTest {
  name = "agent-runtime-factum-devenv-projection";
  nodes.machine = {
    virtualisation.memorySize = 12288;
    virtualisation.cores = 4;
    # NixOS test VMs default to panic_on_oom=2, which panics the whole VM on
    # an instance cgroup OOM. Match the runtime preflight's supported host
    # values so the test can observe and report a contained instance failure.
    boot.kernel.sysctl."vm.panic_on_oom" = 1;
    virtualisation.diskSize = 98304;
    networking.firewall.enable = false;
    networking.dhcpcd.denyInterfaces = [ "ve-*" ];
    virtualisation.additionalPaths = [ projectedEnv requestPath failureRequestJson brokenSourceRequestJson profileBootstrap project manifest skills vendor ];
    environment.systemPackages = with pkgs; [ util-linux coreutils jq procps git runtime.tools.verify ];
  };
  testScript = ''
    import json
    import time
    M = "${manifest}"
    POLICY = "${manifestData.hostPolicy}"
    I = "${I}"
    VERIFY = "${VERIFY}"
    REVISION = "${expectedRequest.sha}"
    RUNNER = "${runner}"
    REQUEST = "${requestPath}"
    CAPTURED_RUST_VERSION = ${builtins.toJSON capturedRustVersion}
    FAILURE_REQUEST = "${failureRequestJson}"
    BROKEN_SOURCE_REQUEST = "${brokenSourceRequestJson}"
    V = "/var/lib/agent-runtime"

    def status(i):
        return json.loads(machine.succeed(f"{I} status {i}"))

    machine.wait_for_unit("multi-user.target")
    machine.succeed(f"{I} create factum --template {M} --host {POLICY} --task sammasak/factum#{REVISION}")
    workspace = f"{V}/factum/vol/workspace/workspace/factum"
    machine.succeed(f"printf '[safe]\\n\\tdirectory = /workspace/factum\\n' > {V}/factum/vol/home/.gitconfig")
    machine.succeed(f"GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0={workspace} git -C {workspace} init -q && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0={workspace} git -C {workspace} add -A -f && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0={workspace} git -C {workspace} -c user.name=agent -c user.email=agent@example.invalid commit -q -m workspace")
    volume_mounts = {name: f"{V}/factum/vol/{name}" for name in ("workspace", "home", "tmp", "cache", "output")}
    filesystem = json.loads(machine.succeed(f"cat {M}"))["filesystem"]
    budgets = {
        name: filesystem["workspaceBudget" if name == "workspace" else name]
        for name in volume_mounts
    }
    peaks = {name: {"used_bytes": 0, "used_inodes": 0} for name in volume_mounts}

    def sample_volumes():
        for name, path in volume_mounts.items():
            used_bytes, used_inodes = map(
                int,
                machine.succeed(f"df -B1 --output=used,iused {path} | tail -n1").split(),
            )
            peaks[name]["used_bytes"] = max(peaks[name]["used_bytes"], used_bytes)
            peaks[name]["used_inodes"] = max(peaks[name]["used_inodes"], used_inodes)

    def assert_within_budgets():
        for name, peak in peaks.items():
            budget = budgets[name]
            assert peak["used_bytes"] < budget["sizeMiB"] * 1024 * 1024, (name, peak, budget)
            assert peak["used_inodes"] < budget["inodes"], (name, peak, budget)

    sample_volumes()
    started = time.monotonic()
    machine.succeed(f"{I} start factum --request {REQUEST} -- {RUNNER}")
    started_record = json.loads(machine.succeed(f"cat {V}/factum/started.json"))
    request_sha = machine.succeed(f"sha256sum {REQUEST} | cut -d' ' -f1").strip()
    assert started_record["requestSha256"] == request_sha, started_record
    s = status("factum")
    while s["state"] in ("starting", "running"):
        sample_volumes()
        if time.monotonic() - started > 2700:
            raise AssertionError(f"Factum runtime exceeded 2700 seconds: {s}")
        time.sleep(10)
        s = status("factum")
    sample_volumes()
    assert_within_budgets()
    print("Factum nspawn volume peak usage:", json.dumps({
        name: {
            **usage,
            "budget_bytes": budgets[name]["sizeMiB"] * 1024 * 1024,
            "budget_inodes": budgets[name]["inodes"],
        }
        for name, usage in peaks.items()
    }, sort_keys=True))
    print("Factum runtime terminal status:", json.dumps(s, sort_keys=True))
    assert s["state"] == "succeeded", s
    output = f"{V}/factum/vol/output"
    result = json.loads(machine.succeed(f"cat {output}/result.json"))
    assert result["check_exit"] == 0, result
    assert result["environment"]["profile"].startswith("/nix/store/"), result
    assert len(result["tool_versions"]) == 1 and result["tool_versions"][0]["name"] == "rust", result
    assert result["tool_versions"][0]["declared"] == CAPTURED_RUST_VERSION, result
    assert CAPTURED_RUST_VERSION in result["tool_versions"][0]["actual"], result
    machine.succeed(f"test -s {output}/check.log")
    machine.succeed(f"grep -q 'test result: ok' {output}/check.log")
    # Factum's nested test-plan cases create temporary Git repos under ignored target/;
    # remove build scratch before the runtime's source exporter rejects nested .git trees.
    machine.succeed(f"rm -rf {workspace}/target")
    machine.succeed(f"{I} export factum")
    bundle = f"{V}/exports/factum"
    verification = json.loads(machine.succeed(f"{VERIFY} --bundle {bundle} --template {M}"))
    assert verification["kind"] == "agent-runtime-verified", verification
    record = json.loads(machine.succeed(f"cat {bundle}/bundle.json"))
    assert record["outcome"] == "succeeded", record
    files = {entry["path"]: entry for entry in record["files"]}
    assert files.get("output/check.log", {}).get("bytes", 0) > 0, record
    assert files.get("output/result.json", {}).get("bytes", 0) > 0, record
    machine.succeed(f"{I} destroy factum")
    machine.succeed(f"test -s {bundle}/bundle.json -a -s {bundle}/output/check.log -a -s {bundle}/output/result.json")
    machine.succeed("! findmnt -rn | grep -qE 'agent-runtime[-/]factum(/| |$)'")
    machine.succeed("! systemctl list-units --all --no-legend agent-runtime-factum.service | grep -q .")
    machine.succeed(f"test ! -e {V}/factum -a ! -e /run/agent-runtime/factum")

    # Cancel a real long-running Factum request after its Cargo process and
    # check log exist. The finished failure case below covers check errors;
    # this one covers an operator interruption while the requested command is
    # still running.
    machine.succeed(f"{I} create factum-cancel --template {M} --host {POLICY} --task sammasak/factum#{REVISION}")
    cancel_workspace = f"{V}/factum-cancel/vol/workspace/workspace/factum"
    machine.succeed(f"printf '[safe]\\n\\tdirectory = /workspace/factum\\n' > {V}/factum-cancel/vol/home/.gitconfig")
    machine.succeed(f"GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0={cancel_workspace} git -C {cancel_workspace} init -q && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0={cancel_workspace} git -C {cancel_workspace} add -A -f && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0={cancel_workspace} git -C {cancel_workspace} -c user.name=agent -c user.email=agent@example.invalid commit -q -m workspace")
    machine.succeed(f"{I} start factum-cancel --request {REQUEST} -- {RUNNER}")
    machine.wait_until_succeeds(f"{I} status factum-cancel | jq -e '.state == \"running\"'", timeout=60)
    machine.wait_until_succeeds("pgrep -x cargo >/dev/null", timeout=120)
    machine.wait_until_succeeds(f"test -e {V}/factum-cancel/vol/output/check.log", timeout=30)
    cargo_pids = machine.succeed("pgrep -x cargo").split()
    cargo_cgroups = [machine.succeed(f"cat /proc/{pid}/cgroup").strip() for pid in cargo_pids]
    assert any("agent-runtime-factum-cancel.service" in group for group in cargo_cgroups), cargo_cgroups
    machine.succeed(f"{I} cancel factum-cancel")
    cancelled = status("factum-cancel")
    assert cancelled["state"] == "cancelled" and cancelled["result"]["serviceResult"], cancelled
    cancelled_retry = json.loads(machine.succeed(f"{I} start factum-cancel --request {REQUEST} -- {RUNNER}"))
    assert cancelled_retry["state"] == "cancelled" and cancelled_retry["result"]["invocation"] == cancelled["result"]["invocation"], cancelled_retry
    machine.succeed(f"{I} export factum-cancel")
    cancel_bundle = f"{V}/exports/factum-cancel"
    cancel_verification = json.loads(machine.succeed(f"{VERIFY} --bundle {cancel_bundle} --template {M}"))
    assert cancel_verification["kind"] == "agent-runtime-verified", cancel_verification
    assert cancel_verification["outcome"] == "cancelled", cancel_verification
    cancel_record = json.loads(machine.succeed(f"cat {cancel_bundle}/bundle.json"))
    assert cancel_record["recovery"] and any(item["path"] == "output/check.log" for item in cancel_record["files"]), cancel_record
    machine.succeed(f"{I} destroy factum-cancel")
    machine.succeed(f"test -s {cancel_bundle}/bundle.json -a -e {cancel_bundle}/output/check.log")
    machine.succeed("! findmnt -rn | grep -qE 'agent-runtime[-/]factum-cancel(/| |$)'")
    machine.succeed("! systemctl list-units --all --no-legend agent-runtime-factum-cancel.service | grep -q .")
    machine.succeed(f"test ! -e {V}/factum-cancel -a ! -e /run/agent-runtime/factum-cancel")

    # Exercise a source-bound explicit command failure against the same real
    # Factum environment. This absent Cargo target fails before compilation.
    machine.succeed(f"{I} create factum-failure --template {M} --host {POLICY} --task sammasak/factum#{REVISION}")
    failure_workspace = f"{V}/factum-failure/vol/workspace/workspace/factum"
    machine.succeed(f"printf '[safe]\\n\\tdirectory = /workspace/factum\\n' > {V}/factum-failure/vol/home/.gitconfig")
    machine.succeed(f"GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0={failure_workspace} git -C {failure_workspace} init -q && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0={failure_workspace} git -C {failure_workspace} add -A -f && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0={failure_workspace} git -C {failure_workspace} -c user.name=agent -c user.email=agent@example.invalid commit -q -m workspace")
    machine.succeed(f"{I} start factum-failure --request {FAILURE_REQUEST} -- {RUNNER}")
    failed = status("factum-failure")
    while failed["state"] in ("starting", "running"):
        time.sleep(1)
        failed = status("factum-failure")
    assert failed["state"] == "failed" and failed["result"]["exitStatus"] == 101, failed
    failed_invocation = failed["result"]["invocation"]
    retry_status = json.loads(machine.succeed(f"{I} start factum-failure --request {FAILURE_REQUEST} -- {RUNNER}"))
    assert retry_status["state"] == "failed" and retry_status["result"]["invocation"] == failed_invocation, retry_status
    failure_output = f"{V}/factum-failure/vol/output"
    machine.succeed(f"grep -q 'no test target named' {failure_output}/check.log")
    machine.succeed(f"rm -rf {failure_workspace}/target")
    machine.succeed(f"{I} export factum-failure")
    failure_bundle = f"{V}/exports/factum-failure"
    failure_verification = json.loads(machine.succeed(f"{VERIFY} --bundle {failure_bundle} --template {M}"))
    assert failure_verification["kind"] == "agent-runtime-verified", failure_verification
    assert failure_verification["outcome"] == "failed", failure_verification
    failure_record = json.loads(machine.succeed(f"cat {failure_bundle}/bundle.json"))
    assert failure_record["outcome"] == "failed", failure_record
    failure_files = {entry["path"]: entry for entry in failure_record["files"]}
    assert failure_files.get("output/check.log", {}).get("bytes", 0) > 0, failure_record
    machine.succeed(f"{I} destroy factum-failure")
    machine.succeed(f"test -s {failure_bundle}/bundle.json -a -s {failure_bundle}/output/check.log")
    machine.succeed("! findmnt -rn | grep -qE 'agent-runtime[-/]factum-failure(/| |$)'")
    machine.succeed("! systemctl list-units --all --no-legend agent-runtime-factum-failure.service | grep -q .")
    machine.succeed(f"test ! -e {V}/factum-failure -a ! -e /run/agent-runtime/factum-failure")

    # Model a rescue editing shell against a broken candidate: edit the source
    # through the active guest shell, prove cargo still runs, then let the
    # source-format check fail on that exact edited file and export the patch.
    machine.succeed(f"{I} create factum-broken --template {M} --host {POLICY} --task sammasak/factum#{REVISION}")
    broken_workspace = f"{V}/factum-broken/vol/workspace/workspace/factum"
    machine.succeed(f"printf '[safe]\\n\\tdirectory = /workspace/factum\\n' > {V}/factum-broken/vol/home/.gitconfig")
    machine.succeed(f"GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0={broken_workspace} git -C {broken_workspace} init -q && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0={broken_workspace} git -C {broken_workspace} add -A -f && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0={broken_workspace} git -C {broken_workspace} -c user.name=agent -c user.email=agent@example.invalid commit -q -m workspace")
    source_blob_before = machine.succeed(f"git hash-object {broken_workspace}/src/lib.rs").strip()
    machine.succeed(f"{I} start factum-broken --request {BROKEN_SOURCE_REQUEST} -- {RUNNER}")
    broken = status("factum-broken")
    while broken["state"] in ("starting", "running"):
        time.sleep(1)
        broken = status("factum-broken")
    assert broken["state"] == "failed" and broken["result"]["exitStatus"] != 0, broken
    broken_output = f"{V}/factum-broken/vol/output"
    broken_log = machine.succeed(f"cat {broken_output}/check.log")
    cargo_versions = [line for line in broken_log.splitlines() if line.startswith("cargo ")]
    assert len(cargo_versions) == 2 and all("1.99.0" in line for line in cargo_versions), broken_log
    assert "error:" in broken_log.lower(), broken_log
    source_blob_after = machine.succeed(f"git hash-object {broken_workspace}/src/lib.rs").strip()
    assert source_blob_before != source_blob_after, (source_blob_before, source_blob_after)
    machine.succeed(f"{I} export factum-broken")
    broken_bundle = f"{V}/exports/factum-broken"
    broken_verification = json.loads(machine.succeed(f"{VERIFY} --bundle {broken_bundle} --template {M}"))
    assert broken_verification["kind"] == "agent-runtime-verified", broken_verification
    assert broken_verification["outcome"] == "failed", broken_verification
    machine.succeed(f"grep -Fq '+pub fn broken( {{' {broken_bundle}/sources/factum.patch")
    machine.succeed(f"{I} destroy factum-broken")
    machine.succeed(f"test -s {broken_bundle}/bundle.json -a -s {broken_bundle}/sources/factum.patch -a -s {broken_bundle}/output/check.log")
    machine.succeed("! findmnt -rn | grep -qE 'agent-runtime[-/]factum-broken(/| |$)'")
    machine.succeed("! systemctl list-units --all --no-legend agent-runtime-factum-broken.service | grep -q .")
    machine.succeed(f"test ! -e {V}/factum-broken -a ! -e /run/agent-runtime/factum-broken")
    machine.succeed("! machinectl list --no-legend | grep -q agent-runtime-")
    machine.succeed("! losetup -l -n -O BACK-FILE | grep -q agent-runtime")
  '';
}
