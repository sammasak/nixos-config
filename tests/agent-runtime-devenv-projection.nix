# devenv-platform#93: the complete generated Devenv environment and enterShell
# output are captured on the host and activated only inside the existing nspawn
# runtime. The env JSON and its profile are inputs to this test via the focused
# script, which runs `devenv print-dev-env --json` before building this VM test.
{ pkgs, lib, envJsonPath, profilePath, skills }:
let
  envJson = builtins.storePath envJsonPath;
  profile = builtins.storePath profilePath;
  fixtureSrc = pkgs.runCommandLocal "native-devenv-projection-fixture" { } ''
    mkdir -p "$TMPDIR/fixture/nested"
    cp -r ${./fixtures/native-devenv-projection}/. "$TMPDIR/fixture/"
    chmod -R u+w "$TMPDIR/fixture"
    cp "$TMPDIR/fixture/devenv.lock" "$TMPDIR/fixture/Makefile" "$TMPDIR/fixture/nested/"
    ln -s nested "$TMPDIR/fixture/alias"
    mv "$TMPDIR/fixture" "$out"
  '';
  fixtureRev = builtins.substring 0 40 (builtins.hashString "sha1" (baseNameOf (toString fixtureSrc)));
  fixtureNar = lib.fileContents (pkgs.runCommand "native-devenv-projection-narhash" { nativeBuildInputs = [ pkgs.nix ]; } ''
    nix --extra-experimental-features nix-command hash path ${fixtureSrc} > $out
  '');
  fixtureLockBlob = lib.fileContents (pkgs.runCommand "native-devenv-projection-lock-blob" { nativeBuildInputs = [ pkgs.git ]; } ''
    git hash-object ${fixtureSrc}/devenv.lock | tr -d '\n' > $out
  '');
  badJson = pkgs.writeText "native-devenv-projection-unsafe.json" (builtins.toJSON {
    schema_version = 1;
    check = "touch /workspace/projection/.unsafe-check-ran";
    variables = {
      DEVENV_PROFILE = { type = "exported"; value = "/home/host/.cache/profile"; };
      DEVENV_ROOT = { type = "exported"; value = "__PROJECT_ROOT__"; };
      DEVENV_RUNTIME = { type = "exported"; value = "__DEVENV_RUNTIME__"; };
      shellHook = { type = "exported"; value = "touch /workspace/projection/.unsafe-hook-ran"; };
    };
  });
  projection = import ../modules/agent-runtime/devenv-projection.nix { inherit lib pkgs; } {
    inherit envJson profile;
    projectRoot = "/workspace/projection";
  };
  request = {
    schema_version = 1;
    kind = "devenv-platform/execution-request";
    status = "ready";
    source = {
      repo = "sammasak/native-devenv-projection-fixture";
      ref = "main";
      sha = fixtureRev;
      root = ".";
      url = "https://github.com/sammasak/native-devenv-projection-fixture";
    };
    environment = { index = 0; kind = "devenv"; root = "."; shell = "devenv"; evidence = [ "e1" ]; };
    target_system = pkgs.stdenv.hostPlatform.system;
    tools = [ { name = "rust"; version = pkgs.rustc.version; evidence = [ "e1" ]; } ];
    check = { index = 0; argv = [ "make" "check" ]; evidence = [ "e1" ]; selection = "plan"; };
    provenance = {
      plan_sha256 = builtins.hashString "sha256" "fixture-plan";
      lockfiles = [ { path = "devenv.lock"; blob = fixtureLockBlob; evidence = [ "e1" ]; } ];
    };
    blockers = [ ];
  };
  readyRequest = pkgs.writeText "execution-request-ready.json" (builtins.toJSON request);
  argvBoundaryRequest = pkgs.writeText "execution-request-argv-boundary.json" (builtins.toJSON (request // {
    check = request.check // {
      argv = [ "printf" "%s\\n" "literal; touch /workspace/projection/.argv-injection-ran" ];
    };
  }));
  blockedRequest = pkgs.writeText "execution-request-blocked.json" (builtins.toJSON (request // {
    status = "blocked";
    blockers = [ { kind = "envrc_present"; detail = "environment activation is unsupported"; evidence = [ "e1" ]; } ];
  }));
  wrongSourceRequest = pkgs.writeText "execution-request-wrong-source.json" (builtins.toJSON (request // {
    source = request.source // { sha = builtins.hashString "sha1" "another-commit"; };
  }));
  nestedRequest = request // {
    source = request.source // { root = "nested"; };
    environment = request.environment // { root = "nested"; };
    provenance = request.provenance // {
      lockfiles = [ { path = "nested/devenv.lock"; blob = fixtureLockBlob; evidence = [ "e1" ]; } ];
    };
  };
  nestedReadyRequest = pkgs.writeText "execution-request-nested-root.json" (builtins.toJSON nestedRequest);
  unsafeRootRequest = pkgs.writeText "execution-request-unsafe-root.json" (builtins.toJSON (request // {
    source = request.source // { root = "../outside"; };
    environment = request.environment // { root = "../outside"; };
  }));
  symlinkRootRequest = pkgs.writeText "execution-request-symlink-root.json" (builtins.toJSON (request // {
    source = request.source // { root = "alias"; };
    environment = request.environment // { root = "alias"; };
    provenance = request.provenance // {
      lockfiles = [ { path = "alias/devenv.lock"; blob = fixtureLockBlob; evidence = [ "e1" ]; } ];
    };
  }));
  mismatchedRequest = pkgs.writeText "execution-request-mismatched-lock.json" (builtins.toJSON (request // {
    provenance = request.provenance // {
      lockfiles = [ { path = "devenv.lock"; blob = builtins.hashString "sha1" "incorrect-lockfile-blob"; evidence = [ "e1" ]; } ];
    };
  }));
  mismatchedToolRequest = pkgs.writeText "execution-request-mismatched-tool.json" (builtins.toJSON (request // {
    tools = [ { name = "rust"; version = "0.0.0"; evidence = [ "e1" ]; } ];
  }));
  withRequest = name: requestPath: pkgs.runCommand name { nativeBuildInputs = [ pkgs.jq ]; } ''
    ${pkgs.jq}/bin/jq --slurpfile request ${requestPath} '. + { executionRequest: $request[0] }' ${envJson} > "$out"
  '';
  readyEnv = withRequest "devenv-environment-ready-request.json" readyRequest;
  argvBoundaryEnv = withRequest "devenv-environment-argv-boundary-request.json" argvBoundaryRequest;
  blockedEnv = withRequest "devenv-environment-blocked-request.json" blockedRequest;
  mismatchedEnv = withRequest "devenv-environment-mismatched-request.json" mismatchedRequest;
  mismatchedToolEnv = withRequest "devenv-environment-mismatched-tool-request.json" mismatchedToolRequest;
  requestProjection = import ../modules/agent-runtime/devenv-projection.nix { inherit lib pkgs; } {
    envJson = readyEnv;
    inherit profile;
    projectRoot = "/workspace/projection";
    expectedRequest = {
      repo = "sammasak/native-devenv-projection-fixture";
      sha = fixtureRev;
      root = ".";
      target_system = pkgs.stdenv.hostPlatform.system;
      environment_index = 0;
      lockfile = "devenv.lock";
    };
  };
  externalRequestProjection = import ../modules/agent-runtime/devenv-projection.nix { inherit lib pkgs; } {
    inherit envJson profile;
    projectRoot = "/workspace/projection";
    consumeRequest = true;
    expectedRequest = {
      repo = "sammasak/native-devenv-projection-fixture";
      sha = fixtureRev;
      root = ".";
      target_system = pkgs.stdenv.hostPlatform.system;
      environment_index = 0;
      lockfile = "devenv.lock";
    };
  };
  nestedRequestProjection = import ../modules/agent-runtime/devenv-projection.nix { inherit lib pkgs; } {
    inherit envJson profile;
    projectRoot = "/workspace/projection";
    consumeRequest = true;
  };
  argvBoundaryProjection = import ../modules/agent-runtime/devenv-projection.nix { inherit lib pkgs; } {
    envJson = argvBoundaryEnv;
    inherit profile;
    projectRoot = "/workspace/projection";
    expectedRequest = {
      repo = "sammasak/native-devenv-projection-fixture";
      sha = fixtureRev;
      root = ".";
      target_system = pkgs.stdenv.hostPlatform.system;
      environment_index = 0;
      lockfile = "devenv.lock";
    };
  };
  quotedLockfileProjection = import ../modules/agent-runtime/devenv-projection.nix { inherit lib pkgs; } {
    envJson = readyEnv;
    inherit profile;
    projectRoot = "/workspace/projection";
    expectedRequest = {
      repo = "sammasak/native-devenv-projection-fixture";
      sha = fixtureRev;
      root = ".";
      target_system = pkgs.stdenv.hostPlatform.system;
      environment_index = 0;
      lockfile = "devenv.lock'$(touch /workspace/projection/.lockfile-injection-ran)";
    };
  };
  blockedProjection = import ../modules/agent-runtime/devenv-projection.nix { inherit lib pkgs; } {
    envJson = blockedEnv;
    inherit profile;
    projectRoot = "/workspace/projection";
    expectedRequest = {
      repo = "sammasak/native-devenv-projection-fixture";
      sha = fixtureRev;
      root = ".";
      target_system = pkgs.stdenv.hostPlatform.system;
      environment_index = 0;
      lockfile = "devenv.lock";
    };
  };
  mismatchedProjection = import ../modules/agent-runtime/devenv-projection.nix { inherit lib pkgs; } {
    envJson = mismatchedEnv;
    inherit profile;
    projectRoot = "/workspace/projection";
    expectedRequest = {
      repo = "sammasak/native-devenv-projection-fixture";
      sha = fixtureRev;
      root = ".";
      target_system = pkgs.stdenv.hostPlatform.system;
      environment_index = 0;
      lockfile = "devenv.lock";
    };
  };
  mismatchedToolProjection = import ../modules/agent-runtime/devenv-projection.nix { inherit lib pkgs; } {
    envJson = mismatchedToolEnv;
    inherit profile;
    projectRoot = "/workspace/projection";
    expectedRequest = {
      repo = "sammasak/native-devenv-projection-fixture";
      sha = fixtureRev;
      root = ".";
      target_system = pkgs.stdenv.hostPlatform.system;
      environment_index = 0;
      lockfile = "devenv.lock";
    };
  };
  runtime = import ../modules/agent-runtime/lib.nix { inherit lib pkgs; };
  I = lib.getExe runtime.tools.instance;
  runner = lib.getExe projection.runner;
  manifestData = runtime.evalManifests {
    modules = [
      {
        sam.agentRuntime.host = {
          enable = true;
          eligibleTemplates = [ "devenv-projection" ];
          maxConcurrentInstances = 1;
          reserve = { memoryMiB = 512; diskMiB = 1024; };
        };
        sam.agentRuntime.templates.devenv-projection = {
          role = { name = "devenv-projection"; harness = "codex"; };
          repositories.projection = {
            github = "sammasak/native-devenv-projection-fixture";
            ref = { type = "commit"; value = fixtureRev; };
            lock = { rev = fixtureRev; narHash = fixtureNar; outPath = "${fixtureSrc}"; };
            path = "/workspace/projection";
            writable = true;
          };
          skillsSource = skills;
          packages = [ projection.runner requestProjection.runner externalRequestProjection.runner nestedRequestProjection.runner argvBoundaryProjection.runner quotedLockfileProjection.runner blockedProjection.runner mismatchedProjection.runner mismatchedToolProjection.runner ];
          filesystem = {
            workspaceBudget = { sizeMiB = 64; inodes = 4000; };
            home = { sizeMiB = 32; inodes = 2000; };
            tmp = { sizeMiB = 128; inodes = 20000; };
            cache = { sizeMiB = 128; inodes = 20000; };
            output = { sizeMiB = 32; inodes = 1000; };
          };
          resources = { cpus = 1; memoryMiB = 1024; tasksMax = 512; timeoutMinutes = 10; };
        };
      }
    ];
  };
  manifest = "${manifestData.manifestDir}/devenv-projection.json";
  template = manifestData.manifestData.devenv-projection;
in
assert template.policies.network == { egress = "none"; allow = [ ]; };
assert template.policies.capabilities == [ ] && template.policies.privateSources == [ ];
assert template.filesystem.workspaceBudget.sizeMiB == 64 && template.filesystem.output.sizeMiB == 32;
pkgs.testers.runNixOSTest {
  name = "agent-runtime-devenv-projection";
  nodes.machine = {
    virtualisation.memorySize = 3072;
    virtualisation.cores = 2;
    virtualisation.diskSize = 4096;
    networking.firewall.enable = false;
    networking.dhcpcd.denyInterfaces = [ "ve-*" ];
          virtualisation.additionalPaths = [ envJson profile fixtureSrc manifest badJson readyEnv readyRequest blockedRequest wrongSourceRequest nestedReadyRequest unsafeRootRequest symlinkRootRequest argvBoundaryEnv blockedEnv mismatchedEnv mismatchedToolEnv mismatchedToolRequest ];
    environment.systemPackages = with pkgs; [ util-linux coreutils jq procps ];
  };
  testScript = ''
    import json
    M = "${manifest}"
    POLICY = "${manifestData.hostPolicy}"
    I = "${I}"
    V = "/var/lib/agent-runtime"

    def status(i):
        return json.loads(machine.succeed(f"{I} status {i}"))

    def create(i):
        machine.succeed(f"{I} create {i} --template {M} --host {POLICY} --task devenv-platform#93")

    def clean(i):
        machine.succeed(f"{I} destroy {i} --discard")
        machine.succeed(f"! findmnt -rn | grep -qE 'agent-runtime[-/]{i}(/| |$)'")
        machine.succeed(f"! systemctl list-units --all --no-legend 'agent-runtime-{i}.service' | grep -q .")
        machine.succeed(f"test ! -e {V}/{i} -a ! -e /run/agent-runtime/{i}")

    machine.wait_for_unit("multi-user.target")
    machine.succeed("test ! -e ${fixtureSrc}/.devenv-enterShell-ran")

    with subtest("generated Devenv variables, import, and enterShell activate inside nspawn before the project check"):
        create("projected")
        machine.succeed(f"{I} start projected --wait -- ${runner}")
        s = status("projected")
        assert s["state"] == "succeeded", s
        o = f"{V}/projected/vol/output"
        result = json.loads(machine.succeed(f"cat {o}/result.json"))
        assert result["environment"]["marker"] == "generated-devenv-environment", result
        assert result["environment"]["imported"] == "generated-devenv-import", result
        assert result["environment"]["profile"].startswith("/nix/store/"), result
        assert result["check_exit"] == 0, result
        machine.succeed(f"grep -q 'guest-check:generated-devenv-environment:generated-devenv-import' {o}/check.log")
        machine.succeed(f"test -f {V}/projected/vol/workspace/workspace/projection/.devenv-enterShell-ran")
        machine.succeed(f"test -f {V}/projected/vol/workspace/workspace/projection/check.result")
        machine.succeed("test ! -e ${fixtureSrc}/.devenv-enterShell-ran")
        clean("projected")

    with subtest("a ready typed execution request matches the pinned project and runs its argv inside nspawn"):
        create("request-ready")
        machine.succeed(f"{I} start request-ready --wait -- ${lib.getExe requestProjection.runner}")
        s = status("request-ready")
        assert s["state"] == "succeeded", s
        o = f"{V}/request-ready/vol/output"
        result = json.loads(machine.succeed(f"cat {o}/result.json"))
        assert result["check_exit"] == 0, result
        assert len(result["tool_versions"]) == 1 and result["tool_versions"][0]["name"] == "rust", result
        assert result["tool_versions"][0]["declared"] == "${pkgs.rustc.version}", result
        assert result["tool_versions"][0]["actual"].startswith("rustc ${pkgs.rustc.version}"), result
        machine.succeed(f"grep -q 'guest-check:generated-devenv-environment:generated-devenv-import' {o}/check.log")
        machine.succeed(f"test -f {V}/request-ready/vol/workspace/workspace/projection/check.result")
        clean("request-ready")

    with subtest("instance start binds a persisted request to its assigned source for the Devenv runner"):
        create("request-bound")
        machine.succeed(f"{I} start request-bound --request ${readyRequest} --wait -- ${lib.getExe externalRequestProjection.runner}")
        s = status("request-bound")
        assert s["state"] == "succeeded", s
        started = json.loads(machine.succeed(f"cat {V}/request-bound/started.json"))
        expected_request_sha = machine.succeed("sha256sum ${readyRequest} | cut -d' ' -f1").strip()
        assert started["requestSha256"] == expected_request_sha, started
        o = f"{V}/request-bound/vol/output"
        machine.succeed(f"grep -q 'guest-check:generated-devenv-environment:generated-devenv-import' {o}/check.log")
        machine.succeed(f"test -f {V}/request-bound/vol/workspace/workspace/projection/check.result")
        clean("request-bound")

    with subtest("persisted request selects a safe nested project root"):
        create("request-nested-root")
        machine.succeed(f"{I} start request-nested-root --request ${nestedReadyRequest} --wait -- ${lib.getExe nestedRequestProjection.runner}")
        s = status("request-nested-root")
        assert s["state"] == "succeeded", s
        machine.succeed(f"test -f {V}/request-nested-root/vol/workspace/workspace/projection/nested/.devenv-enterShell-ran")
        machine.succeed(f"test -f {V}/request-nested-root/vol/workspace/workspace/projection/nested/check.result")
        clean("request-nested-root")

    with subtest("instance start rejects a request for a different assigned source before launching a unit"):
        create("request-wrong-source")
        rc, out = machine.execute(f"{I} start request-wrong-source --request ${wrongSourceRequest} --wait -- ${lib.getExe externalRequestProjection.runner} 2>&1")
        assert rc != 0 and "match the assigned repository commit" in out, (rc, out)
        assert status("request-wrong-source")["state"] == "created"
        machine.succeed("! systemctl list-units --all --no-legend agent-runtime-request-wrong-source.service | grep -q .")
        clean("request-wrong-source")

    with subtest("instance start rejects a blocked persisted request before launching a unit"):
        create("request-blocked-start")
        rc, out = machine.execute(f"{I} start request-blocked-start --request ${blockedRequest} --wait -- ${lib.getExe externalRequestProjection.runner} 2>&1")
        assert rc != 0 and "ready, supported" in out, (rc, out)
        assert status("request-blocked-start")["state"] == "created"
        machine.succeed("! systemctl list-units --all --no-legend agent-runtime-request-blocked-start.service | grep -q .")
        clean("request-blocked-start")

    with subtest("instance start rejects a traversal project root before launching a unit"):
        create("request-unsafe-root")
        rc, out = machine.execute(f"{I} start request-unsafe-root --request ${unsafeRootRequest} --wait -- ${lib.getExe externalRequestProjection.runner} 2>&1")
        assert rc != 0 and "ready, supported" in out, (rc, out)
        assert status("request-unsafe-root")["state"] == "created"
        machine.succeed("! systemctl list-units --all --no-legend agent-runtime-request-unsafe-root.service | grep -q .")
        clean("request-unsafe-root")

    with subtest("Devenv runner rejects a non-canonical symlink project root"):
        create("request-symlink-root")
        machine.execute(f"{I} start request-symlink-root --request ${symlinkRootRequest} --wait -- ${lib.getExe externalRequestProjection.runner}")
        s = status("request-symlink-root")
        assert s["state"] == "failed" and s["result"]["exitStatus"] == 65, s
        machine.succeed(f"test ! -e {V}/request-symlink-root/vol/workspace/workspace/projection/.devenv-enterShell-ran")
        machine.succeed(f"test ! -e {V}/request-symlink-root/vol/workspace/workspace/projection/check.result")
        clean("request-symlink-root")

    with subtest("argv metacharacters remain literal and are not interpreted by a shell"):
        create("request-argv-boundary")
        machine.succeed(f"{I} start request-argv-boundary --wait -- ${lib.getExe argvBoundaryProjection.runner}")
        s = status("request-argv-boundary")
        assert s["state"] == "succeeded", s
        o = f"{V}/request-argv-boundary/vol/output"
        machine.succeed(f"grep -Fx 'literal; touch /workspace/projection/.argv-injection-ran' {o}/check.log")
        machine.succeed(f"test ! -e {V}/request-argv-boundary/vol/workspace/workspace/projection/.argv-injection-ran")
        clean("request-argv-boundary")

    with subtest("quoted lockfile path is passed as data and rejected before activation"):
        create("request-quoted-lockfile")
        machine.execute(f"{I} start request-quoted-lockfile --wait -- ${lib.getExe quotedLockfileProjection.runner}")
        s = status("request-quoted-lockfile")
        assert s["state"] == "failed" and s["result"]["exitStatus"] == 65, s
        machine.succeed(f"test ! -e {V}/request-quoted-lockfile/vol/workspace/workspace/projection/.lockfile-injection-ran")
        machine.succeed(f"test ! -e {V}/request-quoted-lockfile/vol/workspace/workspace/projection/.devenv-enterShell-ran")
        clean("request-quoted-lockfile")

    with subtest("a blocked typed execution request is rejected before project activation"):
        create("request-blocked")
        machine.execute(f"{I} start request-blocked --wait -- ${lib.getExe blockedProjection.runner}")
        s = status("request-blocked")
        assert s["state"] == "failed" and s["result"]["exitStatus"] == 65, s
        machine.succeed(f"test ! -e {V}/request-blocked/vol/workspace/workspace/projection/.devenv-enterShell-ran")
        clean("request-blocked")

    with subtest("a forged lockfile blob is rejected before project activation"):
        create("request-mismatch")
        machine.execute(f"{I} start request-mismatch --wait -- ${lib.getExe mismatchedProjection.runner}")
        s = status("request-mismatch")
        assert s["state"] == "failed" and s["result"]["exitStatus"] == 65, s
        machine.succeed(f"test ! -e {V}/request-mismatch/vol/workspace/workspace/projection/.devenv-enterShell-ran")
        clean("request-mismatch")

    with subtest("a captured Rust tool version must match the projected guest before the check runs"):
        create("request-tool-mismatch")
        machine.execute(f"{I} start request-tool-mismatch --wait -- ${lib.getExe mismatchedToolProjection.runner}")
        s = status("request-tool-mismatch")
        assert s["state"] == "failed" and s["result"]["exitStatus"] == 65, s
        machine.succeed(f"test -f {V}/request-tool-mismatch/vol/workspace/workspace/projection/.devenv-enterShell-ran")
        machine.succeed(f"test ! -e {V}/request-tool-mismatch/vol/workspace/workspace/projection/check.result")
        machine.succeed(f"test ! -e {V}/request-tool-mismatch/vol/output/check.log")
        clean("request-tool-mismatch")

    with subtest("unsafe host-local profile is rejected before the hook or project check runs"):
        create("unsafe")
        machine.execute(f"{I} start unsafe --wait -- ${runner} ${badJson}")
        s = status("unsafe")
        assert s["state"] == "failed" and s["result"]["exitStatus"] == 65, s
        machine.succeed(f"grep -q 'projection rejected' {V}/unsafe/vol/output/stderr.log || journalctl -u agent-runtime-unsafe.service --no-pager -o cat | grep -q 'projection rejected'")
        machine.succeed(f"test ! -e {V}/unsafe/vol/workspace/workspace/projection/.unsafe-hook-ran")
        machine.succeed(f"test ! -e {V}/unsafe/vol/workspace/workspace/projection/.unsafe-check-ran")
        clean("unsafe")

    machine.succeed("! machinectl list --no-legend | grep -q agent-runtime-")
    machine.succeed("! losetup -l -n -O BACK-FILE | grep -q agent-runtime")
  '';
}
