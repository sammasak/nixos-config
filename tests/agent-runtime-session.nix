# The interactive session path in one QEMU VM, with a stub line-echo program in place of Claude Code:
# a session template's payload runs under the runtime's dtach PTY inside a real nspawn instance, the
# host's session.attachUser attaches from outside it with no root, and that user drives the whole
# lifecycle through the one sudo helper. Offline, no real credential. What Herdr makes of a pane whose
# foreground process is named `claude` is proven live only (docs/agent-runtime-session.md).
#   nix build .#packages.x86_64-linux.agent-runtime-session-test
{ pkgs, lib, skills }:
let
  runtime = import ../modules/agent-runtime/lib.nix { inherit lib pkgs; };
  linked = pkgs.writeText "session-linked" "linked-content\n";
  linkedDir = pkgs.runCommand "session-linked-dir" { } ''mkdir -p $out/sub; echo nested > $out/sub/file'';
  seed = pkgs.writeText "session-seed.json" ''{"seed":true}'';
  # facts land in the output volume (exported), then lines are echoed until `quit` or `fail`
  stub = pkgs.writeShellScriptBin "session-stub" ''
    {
      echo "args=$*"
      echo "uid=$(id -u) cwd=$PWD term=$TERM lang=$LANG extra=''${STUB_EXTRA:-}"
      echo "token_sha=$(printf %s "''${STUB_TOKEN:-}" | sha256sum | cut -d' ' -f1)"
      echo "link=$(readlink "$HOME/.stub/linked") $(cat "$HOME/.stub/linked")"
      echo "dir=$(cat "$HOME/.stub/tree/sub/file")"
      echo "copy=$(stat -c '%a %u %F' "$HOME/.stub.json") $(cat "$HOME/.stub.json")"
      echo "parent=$(stat -c '%a %u' "$HOME/.stub")"
      echo appended >>"$HOME/.stub.json" && echo "copy_writable=yes"
      echo "size=$(stty size)"
    } >"$AGENT_RUNTIME_OUTPUT/facts" 2>&1
    echo "stub ready"
    while read -r line; do
      case $line in
        quit) echo bye; exit 0 ;;
        later) sleep 6; exit 0 ;;
        fail) exit 3 ;;
        *) echo "echo:$line" ;;
      esac
    done
  '';
  headless = pkgs.writeShellScriptBin "session-headless" "echo headless";
  # a hook that records exactly the variables the watcher exports, and a `herdr` that records its argv
  hookLog = pkgs.writeShellScript "session-hook-log" ''
    ${lib.getExe pkgs.jq} -nc 'env | with_entries(select(.key | startswith("AGENT_RUNTIME_SESSION_")))
      | . + {uid: "'"$(id -u)"'", herdrSocket: (env.HERDR_SOCKET_PATH // null)}' >>"$HOME/hooks.log"
  '';
  herdrStub = pkgs.writeShellScriptBin "herdr" ''
    ${lib.getExe pkgs.jq} -nc '$ARGS.positional' --args -- "$@" >>"$HOME/herdr.log"
  '';
  base = entry: {
    role = { name = "quality"; harness = "claude-code"; };
    skillsSource = skills;
    skills.lean-code = { };
    packages = [ entry pkgs.bash pkgs.coreutils ];
    filesystem = {
      workspaceBudget = { sizeMiB = 16; inodes = 1000; };
      home = { sizeMiB = 16; inodes = 1000; };
      tmp = { sizeMiB = 16; inodes = 1000; };
      cache = { sizeMiB = 16; inodes = 1000; };
      output = { sizeMiB = 16; inodes = 1000; };
    };
    resources = { cpus = 1; memoryMiB = 128; tasksMax = 64; timeoutMinutes = 10; };
  };
  rt = {
    sam.agentRuntime = {
      host = {
        enable = true;
        eligibleTemplates = [ "sess" "plain" ];
        maxConcurrentInstances = 1;
        reserve = { memoryMiB = 256; diskMiB = 512; };
      };
      session = {
        attachUser = "op";
        credentialFile = "/run/op-token";
        defaultTask = "sammasak/nixos-config#1";
        hookTimeoutSec = 3;
        # the failing and the hanging hook come first: neither may keep the others from running
        hooks.start = [ "exit 7" "${hookLog}" "${lib.getExe runtime.tools.sessionNotify}" ];
        hooks.end = [ "exit 7" "sleep 600" "${hookLog}" "${lib.getExe runtime.tools.sessionNotify}" ];
        launch.enable = true;
      };
      templates.plain = base headless;
      templates.sess = base stub // {
        environment.STUB_EXTRA = "from template";
        homeFiles = {
          ".stub/linked".source = "${linked}";
          ".stub/tree".source = "${linkedDir}";
          ".stub.json" = { source = "${seed}"; mode = "copy"; };
        };
        session = {
          enable = true;
          args = [ "--flag" "two words" ];
          credentialEnv = "STUB_TOKEN";
          workdir = "/workspace";
          paneProcessName = "stubagent";
        };
      };
    };
  };
  evaluated = runtime.evalManifests {
    modules = [ rt { options.sam.agentRuntime.session.launch.enable = lib.mkEnableOption "x"; } ];
  };
  m = evaluated.manifestData.sess;
  env = pkgs.buildEnv { name = "agent-runtime-session-env"; paths = evaluated.templates.sess.packages ++ [ headless ]; };
  I = lib.getExe runtime.tools.instance;
  L = lib.getExe runtime.tools.sessionLaunch;
in
pkgs.testers.runNixOSTest {
  name = "agent-runtime-session";
  nodes.machine = {
    imports = [ ../modules/agent-runtime/host.nix rt ];
    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;
    virtualisation.diskSize = 4096;
    boot.kernel.sysctl."vm.panic_on_oom" = 0;
    networking.firewall.enable = false;
    networking.dhcpcd.denyInterfaces = [ "ve-*" ];
    virtualisation.additionalPaths = [ skills env evaluated.manifestDir linked linkedDir seed ];
    users.users.op = { isNormalUser = true; uid = 1001; linger = true; };
    users.users.eve = { isNormalUser = true; };
    environment.systemPackages = with pkgs; [ util-linux procps gnugrep gawk coreutils jq dtach acl herdrStub ];
  };
  testScript = ''
    import json, time

    M = "${evaluated.manifestDir}/sess.json"
    V = "/var/lib/agent-runtime"
    R = "/run/agent-runtime"
    TOKEN = "sk-ant-oat01-SESSION-stub-secret-value"
    TASK = "sammasak/nixos-config#1"
    L = "${L}"

    def st(i):
        return json.loads(machine.succeed(f"${I} status {i}"))

    # env: the pane's environment (a user manager to hold the watcher unit, Herdr's socket variable)
    PANE = "XDG_RUNTIME_DIR=/run/user/1001 HERDR_SOCKET_PATH=/run/user/1001/herdr.sock"

    def as_user(u, cmd, env=""):
        return f"runuser -u {u} -- env PATH=/run/wrappers/bin:/run/current-system/sw/bin HOME=/home/{u} {env} bash -c '{cmd}'"

    def jsonl(path):
        return [json.loads(l) for l in machine.succeed(f"cat {path} 2>/dev/null || true").splitlines()]

    def hook_events(i):
        return [e for e in jsonl("/home/op/hooks.log") if e["AGENT_RUNTIME_SESSION_ID"] == i]

    # exactly one start and one end for I, the end with OUTCOME and its bundle; returns the end record
    def ended(i, outcome):
        machine.wait_until_succeeds(f"grep -F '\"AGENT_RUNTIME_SESSION_EVENT\":\"end\"' /home/op/hooks.log | grep -qF '\"AGENT_RUNTIME_SESSION_ID\":\"{i}\"'", timeout=90)
        ev = hook_events(i)
        assert [e["AGENT_RUNTIME_SESSION_EVENT"] for e in ev] == ["start", "end"], ev
        start, end = ev
        assert start["AGENT_RUNTIME_SESSION_OUTCOME"] == "" and start["AGENT_RUNTIME_SESSION_TEMPLATE"] == "sess", start
        assert end["AGENT_RUNTIME_SESSION_OUTCOME"] == outcome and end["AGENT_RUNTIME_SESSION_ERROR"] == "", end
        assert end["AGENT_RUNTIME_SESSION_HOST"] == "machine" and end["uid"] == "1001", end
        b = end["AGENT_RUNTIME_SESSION_BUNDLE"]
        assert b.startswith(f"{V}/exports/{i}.runs/") and json.loads(machine.succeed(f"cat {b}/bundle.json"))["outcome"] == outcome, end
        gone(i)
        return end

    # a terminal for USER running CMD: keystrokes go in through a fifo held open, the screen lands in a log
    def term(name, user, cmd, env=""):
        machine.succeed(f"rm -f /tmp/{name}.in /tmp/{name}.log; mkfifo /tmp/{name}.in; chmod 666 /tmp/{name}.in; "
                        f"touch /tmp/{name}.log; chmod 666 /tmp/{name}.log; "
                        f"nohup sh -c 'sleep 900 >/tmp/{name}.in' >/dev/null 2>&1 </dev/null &")
        machine.succeed(as_user(user, f"script -qfec \"{cmd}\" /tmp/{name}.log </tmp/{name}.in >/dev/null 2>&1 &", env))

    def keys(name, text):
        machine.succeed(f"printf '{text}' >/tmp/{name}.in")

    def screen(name, needle, timeout=30):
        machine.wait_until_succeeds(f"grep -qF -- '{needle}' /tmp/{name}.log", timeout=timeout)

    # dtach replays nothing on attach, so "attached" is: the client runs and a typed line comes back
    def joined(name):
        machine.wait_until_succeeds("pgrep -u op -x stubagent", timeout=90)
        keys(name, "ping\\n")
        screen(name, "echo:ping")

    def gone(i):
        machine.succeed(f"test ! -e {V}/{i} -a ! -e {R}/{i}")
        machine.succeed(f"! findmnt -rn | grep -qE 'agent-runtime[-/]{i}(/| |$)'")
        machine.succeed(f"! systemctl list-units --all --no-legend 'agent-runtime-{i}.service' | grep -q .")

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("user@1001.service")
    machine.succeed(f"printf %s {TOKEN} >/root/token && chmod 400 /root/token")
    machine.succeed("install -m 0400 -o op /root/token /run/op-token")
    machine.succeed("mkdir -p /nix/var/nix/profiles/agent-runtime/templates && "
                    "ln -sfn ${evaluated.manifestDir} /nix/var/nix/profiles/agent-runtime/templates/templates")
    print("session template digest ${m.digests.template}")
    assert "${toString m.session.credentialEnv}" == "STUB_TOKEN"

    with subtest("start of a session template: payload from the manifest, PTY socket, placed home files, no secret in argv or records"):
        machine.succeed(f"${I} create s1 --template {M} --task {TASK}")
        machine.succeed("${I} start s1 --credential /root/token")
        s = st("s1")
        assert s["state"] == "running", s
        assert TOKEN not in json.dumps(s), "the credential is in the status record"
        machine.succeed(f"! grep -rqF {TOKEN} {V}/s1/started.json {V}/s1/template.json {R}/s1/session.json {R}/s1/mirror.status")
        assert "session-stub" in s["started"]["command"] and "two\\ words" in s["started"]["command"], s["started"]
        print(machine.succeed(f"ls -la {R}/s1 {R}/s1/session; getfacl -p {R}/s1/session"))
        machine.succeed(f"test -S {R}/s1/session/pty.sock")
        assert machine.succeed(f"stat -c '%U %a' {R}/s1/session").split()[0] == "root"
        sj = json.loads(machine.succeed(f"cat {R}/s1/session.json"))
        assert sj == {"id": "s1", "template": "sess", "task": TASK, "paneProcessName": "stubagent"}, sj
        # argv of every process on the host, the instance's included
        machine.succeed("ps -eo args >/tmp/ps.txt; ! grep -Ff /root/token /tmp/ps.txt")
        base = s["uidBase"]
        machine.wait_until_succeeds(f"test -s {V}/s1/vol/output/facts")
        facts = dict(l.split("=", 1) for l in machine.succeed(f"cat {V}/s1/vol/output/facts").splitlines())
        print(facts)
        sha = machine.succeed(f"printf %s {TOKEN} | sha256sum | cut -d' ' -f1").strip()
        assert facts["args"] == "--flag two words", facts
        assert facts["uid"].startswith("1000 cwd=/workspace term=xterm-256color lang=C.UTF-8 extra=from template"), facts
        assert facts["token_sha"] == sha, "the credential did not reach the session process under credentialEnv"
        assert facts["link"] == "${linked} linked-content" and facts["dir"] == "nested", facts
        assert facts["copy"] == '600 1000 regular file {"seed":true}' and facts["copy_writable"] == "yes", facts
        assert facts["parent"] == "755 1000" and facts["size"] == "40 120", facts
        # the same files from the host: owned by the mapped instance user
        owner = str(base + 1000)
        assert machine.succeed(f"stat -c %u {V}/s1/vol/home/.stub.json {V}/s1/vol/home/.stub {V}/s1/vol/home/.stub/linked").split() == [owner] * 3

    with subtest("attach: the attach user, with no root, types a line and sees the echo; another user is refused"):
        machine.fail(as_user("eve", "agent-runtime-session attach s1"))
        machine.fail(as_user("eve", f"test -e {R}/s1/session/pty.sock"))
        machine.fail(as_user("eve", f"script -qfec \"dtach -a {R}/s1/session/pty.sock\" /dev/null </dev/null"))
        machine.fail(as_user("op", "sudo -n ${I} status s1"))
        term("a1", "op", "agent-runtime-session attach s1")
        machine.wait_until_succeeds("pgrep -u op -x stubagent")
        pid = machine.succeed("pgrep -u op -x stubagent").strip()
        assert machine.succeed(f"cat /proc/{pid}/comm").strip() == "stubagent"
        assert machine.succeed(f"tr '\\0' ' ' </proc/{pid}/cmdline").split()[0].endswith("/stubagent")
        # outside the instance: the client shares the host's namespaces, not the leader's
        leader = st("s1")["started"]["leaderPid"]
        assert machine.succeed(f"readlink /proc/{pid}/ns/user /proc/{pid}/ns/mnt") == machine.succeed("readlink /proc/1/ns/user /proc/1/ns/mnt")
        assert machine.succeed(f"readlink /proc/{pid}/ns/user") != machine.succeed(f"readlink /proc/{leader}/ns/user")
        keys("a1", "hello session\\n")
        screen("a1", "echo:hello session")
        out = machine.succeed(as_user("op", "agent-runtime-session list"))
        assert json.loads(out) == {"id": "s1", "template": "sess", "task": TASK, "state": "starting", "attachable": True}, out

    with subtest("detaching leaves the session running; the program's exit ends the instance succeeded"):
        keys("a1", "\\034")
        machine.wait_until_fails("pgrep -u op -x stubagent")
        time.sleep(2)
        assert st("s1")["state"] == "running"
        term("a2", "op", "agent-runtime-session attach s1")
        machine.wait_until_succeeds("pgrep -u op -x stubagent")
        keys("a2", "again\\n")
        screen("a2", "echo:again")
        keys("a2", "quit\\n")
        machine.wait_until_succeeds("${I} status s1 | jq -e '.state == \"succeeded\"'", timeout=60)
        machine.wait_until_fails("pgrep -u op -x stubagent")
        machine.fail(as_user("op", "agent-runtime-session attach s1"))
        machine.succeed(f"test ! -e {R}/s1/session/pty.sock")
        inv = st("s1")["started"]["invocation"]
        machine.succeed("journalctl --sync || true")
        machine.succeed(f"! journalctl --no-pager -o cat | grep -F {TOKEN}")
        machine.succeed(f"! ${I} logs s1 | grep -F {TOKEN}")
        ex = json.loads(machine.succeed("${I} export s1"))["export"]["dir"]
        machine.succeed(f"! grep -rF {TOKEN} {ex}")
        machine.succeed(f"grep -q copy_writable=yes {ex}/output/facts")
        machine.succeed("${I} destroy s1")
        gone("s1")

    with subtest("a failing session program is a failed instance with its exit status"):
        machine.succeed(f"${I} create s2 --template {M} --task {TASK}")
        machine.succeed("${I} start s2")
        term("a3", "op", "agent-runtime-session attach s2")
        machine.wait_until_succeeds("pgrep -u op -x stubagent")
        keys("a3", "fail\\n")
        machine.wait_until_succeeds("${I} status s2 | jq -e '.state == \"failed\" and .result.exitStatus == 3'", timeout=60)
        # no credential was delivered: the variable stayed unset
        assert "token_sha=e3b0c442" in machine.succeed(f"cat {V}/s2/vol/output/facts")
        machine.succeed("${I} export s2 && ${I} destroy s2")
        gone("s2")

    with subtest("the helper refuses everything but start|end of an eligible session template"):
        def refused(args, why):
            rc, out = machine.execute(as_user("op", f"sudo -n {L} {args} 2>&1"))
            print(args, "=>", rc, out)
            assert rc != 0 and "refused" in out and why in out, (args, rc, out)
            assert st("h1")["state"] == "absent"
        refused(f"start h1 nope {TASK}", "not eligible")
        refused(f"start h1 plain {TASK}", "not a session template")
        refused(f"start ../h1 sess {TASK}", "not a valid runtime id")
        refused(f"start H1 sess {TASK}", "not a valid runtime id")
        refused("start h1 sess not-a-task", "not OWNER/REPO#N")
        refused(f"start h1 sess {TASK} extra", "exactly")
        refused(f"start h1 sess {TASK} -- /bin/sh", "exactly")
        refused("end h1 extra", "exactly")
        refused("destroy h1", "start or end")
        refused(f"start h1 /nix/store/x.json {TASK}", "not a template name")
        # an instance of a headless template is out of the helper's reach
        machine.succeed(f"${I} create h2 --template ${evaluated.manifestDir}/plain.json --task {TASK}")
        rc, out = machine.execute(as_user("op", f"sudo -n {L} end h2 2>&1"))
        assert rc != 0 and "not a session instance" in out, out
        assert st("h2")["state"] == "created"
        machine.succeed("${I} destroy h2")
        # the rule names one command: nothing else runs as root
        machine.fail(as_user("op", "sudo -n ${I} status"))
        machine.fail(as_user("eve", f"sudo -n {L} start h1 sess {TASK}"))

    with subtest("run: one command as the session user; detach keeps it, rejoin, the watcher exports, destroys and runs the hooks"):
        term("r1", "op", "agent-runtime-session run r1", PANE)
        joined("r1")
        pid = machine.succeed("pgrep -u op -x stubagent").strip()
        # the terminal's foreground process group is the client's own, under the pane name
        tp = machine.succeed(f"ps -o tpgid=,pgid=,comm= -p {pid}").split()
        assert tp[0] == tp[1] == pid and tp[2] == "stubagent", tp
        s = st("r1")
        assert s["state"] == "running" and s["task"] == TASK and s["started"]["credential"]["kind"] == "file", s
        sha = machine.succeed(f"printf %s {TOKEN} | sha256sum | cut -d' ' -f1").strip()
        machine.succeed(f"grep -q token_sha={sha} {V}/r1/vol/output/facts")
        machine.succeed("ps -eo args >/tmp/ps.txt; ! grep -Ff /root/token /tmp/ps.txt")
        machine.succeed("journalctl -t agent-runtime-session-launch --no-pager | grep -q '\"decision\":\"authorized\"'")
        # the watcher is the session user's own unit, and the start hook ran once, after the socket
        machine.succeed("systemctl --user -M op@ is-active agent-runtime-session-watch-r1.service")
        machine.wait_until_succeeds("grep -q r1 /home/op/herdr.log")
        ev = hook_events("r1")
        assert len(ev) == 1 and ev[0]["AGENT_RUNTIME_SESSION_EVENT"] == "start" and ev[0]["AGENT_RUNTIME_SESSION_TASK"] == TASK, ev
        assert ev[0]["herdrSocket"] == "/run/user/1001/herdr.sock", "the pane's Herdr socket did not reach the watcher"
        assert jsonl("/home/op/herdr.log") == [["notification", "show", "rt-r1 started on machine", "--body", f"sess {TASK}", "--sound", "none"]]
        keys("r1", "\\034")
        screen("r1", "session r1 is still running (detached)")
        time.sleep(2)
        assert st("r1")["state"] == "running"
        # a second run of the same id starts nothing and no second watcher: it rejoins
        term("r1b", "op", "agent-runtime-session run r1", PANE)
        machine.wait_until_succeeds("pgrep -u op -x stubagent")
        keys("r1b", "quit\\n")
        screen("r1b", "session r1 ended; bundle: /var/lib/agent-runtime/exports/r1.runs/latest", timeout=120)
        end = ended("r1", "succeeded")
        assert jsonl("/home/op/herdr.log")[-1] == ["notification", "show", "rt-r1 succeeded on machine", "--body",
            f"{TASK} {end['AGENT_RUNTIME_SESSION_BUNDLE']}", "--sound", "done"]
        # the failing hook and the one killed at its bound were logged, and changed nothing
        machine.succeed("journalctl -t agent-runtime-session --no-pager | grep -F 'exited 7 (ignored)'")
        machine.succeed("journalctl -t agent-runtime-session --no-pager | grep -F 'sleep 600' | grep -F 'exited 124'")
        machine.succeed(f"! grep -rF {TOKEN} {V}/exports/r1.runs /home/op/hooks.log /home/op/herdr.log")
        machine.succeed(f"! journalctl --no-pager -o cat | grep -F {TOKEN}")

    with subtest("the program ends after its terminal was killed: the watcher still exports, destroys and notifies"):
        term("r3", "op", "agent-runtime-session run r3", PANE)
        joined("r3")
        keys("r3", "later\\n")
        machine.succeed("pkill -KILL -u op -x script; pkill -KILL -u op -x stubagent || true; pkill -KILL -u op -f 'agent-runtime-session run' || true")
        machine.fail("pgrep -u op -x stubagent")
        ended("r3", "succeeded")

    with subtest("a failing program: outcome failed, the request sound"):
        term("r4", "op", "agent-runtime-session run r4", PANE)
        joined("r4")
        keys("r4", "fail\\n")
        end = ended("r4", "failed")
        assert jsonl("/home/op/herdr.log")[-1] == ["notification", "show", "rt-r4 failed on machine", "--body",
            f"{TASK} {end['AGENT_RUNTIME_SESSION_BUNDLE']}", "--sound", "request"]

    with subtest("end: the session user stops a detached session; cancelled, exported once, destroyed; no user manager needed"):
        # no XDG_RUNTIME_DIR: the watcher is a detached process instead of a user unit
        term("r2", "op", "agent-runtime-session run --template sess --task sammasak/rf-proto#7 r2")
        joined("r2")
        keys("r2", "\\034")
        screen("r2", "still running")
        machine.fail("systemctl --user -M op@ is-active agent-runtime-session-watch-r2.service")
        machine.succeed("pgrep -u op -f 'agent-runtime-session _watch r2'")
        out = machine.succeed(as_user("op", "agent-runtime-session end r2 2>/dev/null")).strip().split("\t")
        assert out[0] == "cancelled" and out[1].startswith(f"{V}/exports/r2.runs/"), out
        end = ended("r2", "cancelled")
        assert end["AGENT_RUNTIME_SESSION_BUNDLE"] == out[1] and end["AGENT_RUNTIME_SESSION_TASK"] == "sammasak/rf-proto#7", end
        # the watcher's own end came second: one run, one bundle
        assert machine.succeed(f"ls {V}/exports/r2.runs | grep -vc latest").strip() == "1"
        # ending again is a no-op that still names the bundle
        assert machine.succeed(as_user("op", "agent-runtime-session end r2 2>/dev/null")).strip().split("\t") == out
        assert machine.succeed(as_user("op", "agent-runtime-session list")).strip() == ""
        machine.wait_until_fails("pgrep -u op -f 'agent-runtime-session _watch'")
  '';
}
