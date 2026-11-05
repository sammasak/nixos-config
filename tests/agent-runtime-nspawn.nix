# Proof for the ephemeral nspawn agent runtime (#135 M0, #137 enforcement, #138
# lifecycle): templates declared through the typed module (#134) run as
# user-namespaced systemd-nspawn instances by the shipped agent-runtime-instance
# tool, never by a host switch or a static containers.<name> entry. Runs only in
# QEMU: nix build .#packages.x86_64-linux.agent-runtime-nspawn
{ pkgs, lib, rfProto, skills }:
let
  runtime = import ../modules/agent-runtime/lib.nix { inherit lib pkgs; };
  evaluated = runtime.evalManifests {
    modules = [
      {
        sam.agentRuntime.host = {
          enable = true;
          eligibleTemplates = [ "rust-worker-m0" "tiny" "egress" "ghread" ];
          maxConcurrentInstances = 3;
          reserve = { memoryMiB = 2600; diskMiB = 512; };
        };
        # #137 slice 3: a token minted for the run, scoped to the one declared capability, used against a
        # GitHub stand-in reached through the egress allowlist
        sam.agentRuntime.templates.ghread = {
          role = { name = "rust-worker"; harness = "claude-code"; };
          skillsSource = skills;
          skills.lean-code = { };
          packages = with pkgs; [ bash coreutils curl cacert ];
          network.allow = [ "api.test" ];
          capabilities = [ "github-read" ];
          filesystem = {
            workspaceBudget = { sizeMiB = 16; inodes = 1000; };
            home = { sizeMiB = 16; inodes = 1000; };
            tmp = { sizeMiB = 16; inodes = 1000; };
            cache = { sizeMiB = 16; inodes = 1000; };
            output = { sizeMiB = 16; inodes = 1000; };
          };
          resources = { cpus = 1; memoryMiB = 256; tasksMax = 128; timeoutMinutes = 5; };
        };
        # #137 slice 2: minimal egress to one allowlisted name, and a per-run credential at start
        sam.agentRuntime.templates.egress = {
          role = { name = "rust-worker"; harness = "claude-code"; };
          skillsSource = skills;
          skills.lean-code = { };
          packages = with pkgs; [ bash coreutils curl cacert getent dnsutils ];
          network.allow = [ "allowed.test" ];
          filesystem = {
            workspaceBudget = { sizeMiB = 16; inodes = 1000; };
            home = { sizeMiB = 16; inodes = 1000; };
            tmp = { sizeMiB = 16; inodes = 1000; };
            cache = { sizeMiB = 16; inodes = 1000; };
            output = { sizeMiB = 16; inodes = 1000; };
          };
          resources = { cpus = 1; memoryMiB = 256; tasksMax = 128; timeoutMinutes = 5; };
        };
        sam.agentRuntime.templates.rust-worker-m0 = {
          role = { name = "rust-worker"; harness = "claude-code"; };
          repositories.rf-proto = {
            github = "sammasak/rf-proto";
            ref = { type = "commit"; value = rfProto.rev; };
            lock = rfProto;
            path = "/workspace/rf-proto";
            writable = true;
          };
          skillsSource = skills;
          skills.rust-engineering = { };
          packages = with pkgs; [ bash coreutils findutils gnugrep gnused gawk diffutils util-linux glibc.bin cargo rustc gcc ];
          filesystem = {
            workspaceBudget = { sizeMiB = 256; inodes = 20000; };
            home = { sizeMiB = 64; inodes = 5000; };
            tmp = { sizeMiB = 128; inodes = 20000; };
            cache = { sizeMiB = 128; inodes = 20000; };
            output = { sizeMiB = 32; inodes = 1000; };
          };
          resources = { cpus = 1; memoryMiB = 512; tasksMax = 512; timeoutMinutes = 30; };
        };
        # a second template sharing the host's admission budget
        sam.agentRuntime.templates.tiny = {
          role = { name = "quality"; harness = "codex"; };
          skillsSource = skills;
          skills.lean-code = { };
          packages = with pkgs; [ bash coreutils gnugrep util-linux ];
          filesystem = {
            workspaceBudget = { sizeMiB = 16; inodes = 1000; };
            home = { sizeMiB = 16; inodes = 1000; };
            tmp = { sizeMiB = 16; inodes = 1000; };
            cache = { sizeMiB = 16; inodes = 1000; };
            output = { sizeMiB = 16; inodes = 1000; };
          };
          resources = { cpus = 1; memoryMiB = 64; tasksMax = 64; timeoutMinutes = 5; };
        };
      }
    ];
  };
  hostPolicy = evaluated.host;
  tool = lib.getExe runtime.tools.instance;
  manifest = n: "${evaluated.manifestDir}/${n}.json";
  rust = rec {
    t = evaluated.templates.rust-worker-m0;
    m = evaluated.manifestData.rust-worker-m0;
    fs = m.filesystem;
    src = m.sources.rf-proto;
    env = pkgs.buildEnv { name = "agent-runtime-rust-worker-m0"; paths = t.packages; };
  };
  inherit (rust) fs env;
  ws = fs.workspace;
  out = fs.output.path;
  nsList = "user mnt pid ipc uts net cgroup time";
  probeEnv = pkgs.buildEnv { name = "agent-runtime-probe"; paths = [ env pkgs.hostname-debian ]; };
  closure = pkgs.closureInfo { rootPaths = [ env rust.src.locked.storePath rust.m.skills.source.storePath ]; };
  sh = pkgs.writeShellScript;

  # Runs as container root, with no capabilities: records the boundary and tries to break it.
  probe = sh "agent-probe" ''
    set -u
    export PATH=${probeEnv}/bin
    for n in ${nsList}; do echo "ns_$n: $(readlink /proc/self/ns/$n)"; done
    echo "uid_map: $(tr -s ' ' < /proc/self/uid_map)"
    echo "gid_map: $(tr -s ' ' < /proc/self/gid_map)"
    echo "cgroup: $(cat /proc/self/cgroup)"
    echo "status: $(grep -E '^(Cap(Inh|Prm|Eff|Bnd|Amb)|NoNewPrivs|Seccomp):' /proc/self/status | tr -s '\t ' ' ' | tr '\n' ' ')"
    echo "mountinfo:"; sed 's/^/  /' /proc/self/mountinfo
    echo "dev: $(ls /dev | tr '\n' ' ')"
    echo "net: $(ls /sys/class/net | tr '\n' ' ')"
    echo "pids_visible: $(ls /proc | grep -cE '^[0-9]+$')"
    hostpid=$(cat ${ws}/host.pid)
    fail=0
    chk() { if "$@"; then echo "ok   $*"; else echo "FAIL $*"; fail=1; fi; }
    chk test ! -e /nix/var/nix/daemon-socket/socket
    chk test ! -S /run/systemd/private
    chk test ! -e /run/docker.sock
    chk test ! -e /home/host-sentinel
    chk test ! -e /root/host-sentinel
    chk test -z "''${SSH_AUTH_SOCK:-}"
    echo "fds: $(ls /proc/self/fd | tr '\n' ' ')"
    chk test "$(ls /proc/self/fd | tr '\n' ' ')" = "0 1 2 3 "
    chk test "$(ls /sys/class/net)" = lo
    chk test -f /skills/rust-engineering/SKILL.md
    chk test -f ${ws}/rf-proto/Cargo.toml
    chk test "$(awk '{print $2}' /proc/self/uid_map)" != 0
    chk test "$(awk '{print $2}' /proc/self/gid_map)" != 0
    for c in CapInh CapPrm CapEff CapBnd CapAmb; do chk grep -qE "^$c:\s+0+$" /proc/self/status; done
    chk grep -qE '^NoNewPrivs:\s+1$' /proc/self/status
    chk grep -qE '^Seccomp:\s+2$' /proc/self/status
    chk sh -c '! ipcs -m | grep -q "^0x"'
    deny() { if "$@" 2>/dev/null; then echo "FAIL (succeeded) $*"; fail=1; else echo "denied $*"; fi; }
    deny kill -0 "$hostpid"
    deny touch /nix/store/agent-runtime-write-attempt
    deny touch ${env}/bin/agent-runtime-write-attempt
    deny touch /skills/rust-engineering/agent-runtime-write-attempt
    deny touch ${ws}/root-write-attempt
    deny mount -o remount,rw /nix/store
    deny mount -o remount,rw /
    deny mount -t tmpfs none /tmp
    deny mknod /dev/sda b 8 0
    deny sh -c 'echo 1 > /proc/sys/kernel/sysrq'
    deny test -r /proc/kcore
    deny touch /sys/kernel/agent-runtime-write-attempt
    deny hostname agent-probe-renamed
    echo "nested_userns: $(unshare --user --map-root-user true 2>&1; echo "exit=$?")"
    chk sh -c 'echo probe > ${fs.tmp.path}/probe.txt'
    exit $fail
  '';

  # The real job, as `agent`: test the pinned source, change it, leave an untracked
  # binary file and an artifact, so the export has a patch, a binary and output.
  work = sh "agent-work" ''
    set -euo pipefail
    export PATH=${env}/bin CARGO_HOME=${fs.cache.path}/cargo
    echo "started_ns=$(date +%s%N)"
    echo "whoami=$(id -u):$(id -g) home=$(stat -c %u:%a $HOME) cache=$(stat -c %u:%a ${fs.cache.path}) tmp=$(stat -c %a $TMPDIR)"
    echo "status: $(grep -E '^(CapEff|CapBnd|NoNewPrivs|Seccomp):' /proc/self/status | tr -s '\t ' ' ' | tr '\n' ' ')"
    touch $HOME/.written ${fs.cache.path}/.written $TMPDIR/.written
    cd ${ws}/rf-proto
    cargo test --offline 2>&1 | tee ${out}/cargo-test.log
    test "''${PIPESTATUS[0]}" = 0
    echo "edited by $AGENT_RUNTIME_INSTANCE" >> README.md
    head -c 4096 /dev/urandom > untracked-artifact.bin
    cp "$(find target/debug/deps -maxdepth 1 -type f -perm -u+x -name 'rf_proto-*' | head -1)" ${out}/rf_proto-test
    (cd ${out} && sha256sum rf_proto-test > SHA256SUMS)
    if touch /nix/store/agent-runtime-write-attempt 2>/dev/null; then echo "FAIL store writable"; exit 1; fi
    echo "finished_ns=$(date +%s%N)"
  '';

  # Holds until the host's go; must see only its own marker and SysV segment and
  # must not reach the peer whose leader PID the host writes in.
  hold = sh "agent-hold" ''
    set -euo pipefail
    me=$(cat /proc/sys/kernel/hostname)
    echo "$me" > ${ws}/marker-$me
    ipcmk -M 4096 > /dev/null
    touch ${ws}/ready
    while [ ! -e ${ws}/go ]; do sleep 0.2; done
    test "$(ls ${ws} | grep -c '^marker-')" = 1
    test "$(ipcs -m | grep -c '^0x')" = 1
    if kill -0 "$(cat ${ws}/peer.pid)" 2>/dev/null; then echo "FAIL peer signalable"; exit 1; fi
    echo "held as $me: own marker and segment only, peer $(cat ${ws}/peer.pid) not signalable"
  '';
  sleeper = sh "agent-sleep" "touch ${ws}/ready; exec sleep 600";
  forkbomb = sh "agent-pids" ''
    # xargs waits for a child and retries on EAGAIN, so the bomb sits at the limit and then ends
    seq 1 ${toString (rust.t.resources.tasksMax + 200)} | xargs -P 0 -I{} sleep 10
  '';
  hog = sh "agent-oom" "head -c ${toString (rust.t.resources.memoryMiB * 2)}M /dev/zero | tail > /dev/null";
  spin = sh "agent-cpu" ''
    for i in 1 2 3; do (while :; do :; done) & done
    sleep 5
    kill $(jobs -p)
  '';
  fill = sh "agent-fill" ''
    dd if=/dev/zero of=${ws}/fill bs=1M 2> $TMPDIR/dd.err; echo "dd_exit=$?"; head -1 $TMPDIR/dd.err
    cd $HOME
    seq 1 ${toString (fs.home.inodes * 2)} | xargs touch 2> $TMPDIR/touch.err; echo "touch_exit=$?"; head -1 $TMPDIR/touch.err
    df -i $HOME | tail -1
    exit 3
  '';
  marker = sh "agent-marker" "echo ran > ${ws}/payload-ran";
  eg = evaluated.manifestData.egress;
  egEnv = pkgs.buildEnv { name = "agent-runtime-egress-env"; paths = evaluated.templates.egress.packages; };
  tlsEndpoint = pkgs.writeText "tls-endpoint.py" ''
    import http.server, ssl
    def get(s):
        s.send_response(200); s.send_header("Content-Length", "11"); s.send_header("Connection", "close"); s.end_headers()
        s.wfile.write(b"endpoint-ok")
    h = type("H", (http.server.BaseHTTPRequestHandler,), {"protocol_version": "HTTP/1.0", "do_GET": get})
    import sys
    srv = http.server.ThreadingHTTPServer((sys.argv[1], 443), h)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain("/tmp/ca.pem", "/tmp/k.pem")
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True); srv.serve_forever()
  '';
  # the egress payload (inside the instance, uid 1000): the allowlisted name over TLS works; a denied local
  # IP and a denied IP reachable only by routing off the host are both refused.
  egWork = sh "agent-egress" ''
    set -u
    export PATH=${egEnv}/bin SSL_CERT_FILE=${eg.filesystem.workspace}/ca.pem
    ab=$(curl -sS --max-time 8 https://allowed.test/ 2>&1); arc=$?
    echo "allowed: rc=$arc body=[$ab]"
    echo -n "denied-local: "; if curl -sS --max-time 8 -k https://10.9.0.9/ >/dev/null 2>&1; then echo REACHED; else echo "REFUSED rc=$?"; fi
    echo -n "denied-routed: "; if curl -sS --max-time 8 -k https://10.8.0.5/ >/dev/null 2>&1; then echo REACHED; else echo "REFUSED rc=$?"; fi
    # DNS is closed: only the pinned allowlist resolves, and a raw query to a resolver (on the host, or routed
    # off it) gets no answer, though both resolvers answer the host itself
    # getaddrinfo, as curl resolves; the pinned name must resolve, or the denied result proves nothing
    p=$(getent ahostsv4 allowed.test 2>&1); prc=$?; echo "pinned-name: rc=$prc $(echo "$p" | head -1)"
    d=$(getent ahostsv4 denied.test 2>&1); drc=$?; echo "denied-name: rc=$drc [$(echo "$d" | head -1)]"
    for r in 10.9.0.1 10.8.0.5; do
      a=$(dig +time=2 +tries=1 +short @$r allowed.test 2>&1); rc=$?
      if [ "$rc" = 0 ] && [ -n "$a" ]; then echo "raw-dns $r: ANSWERED $a"; else echo "raw-dns $r: REFUSED rc=$rc"; fi
    done
    # held alive on request, so the host can read the instance's veth pairing while it still exists
    if [ -e ${eg.filesystem.workspace}/hold ]; then echo held; while [ ! -e ${eg.filesystem.workspace}/release ]; do sleep 0.2; done; fi
  '';
  # two credential instances at once: each holds its own token and tries the other's host path and every
  # other route a token could take into its namespace
  credPeer = sh "agent-cred-peer" ''
    set -u
    export PATH=${tnEnv}/bin
    w=${tn.filesystem.workspace}
    touch $w/ready
    while [ ! -e $w/go ]; do sleep 0.2; done
    echo "own: $(sha256sum < /run/agent-runtime/credentials/token | cut -c1-16)"
    peer=$(cat $w/peer)
    if cat "/run/agent-runtime/$peer/cred/token" 2>/dev/null; then echo "FAIL read the peer token at its host path"; exit 1; fi
    echo "credentials dir: $(ls /run/agent-runtime/credentials | tr '\n' ' ')"
    test "$(ls /run/agent-runtime)" = credentials || { echo "FAIL more than our credentials under /run/agent-runtime"; exit 1; }
    # every file named token this instance can see (the template has no find; bash globstar walks the trees)
    shopt -s globstar nullglob
    tokens=(/run/**/token /tmp/**/token /home/**/token /var/**/token /etc/**/token ${tn.filesystem.workspace}/**/token ${tn.filesystem.output.path}/**/token)
    test "''${tokens[*]}" = /run/agent-runtime/credentials/token || { echo "FAIL token files here: ''${tokens[*]}"; exit 1; }
    echo "peer $peer: its token is not readable from here"
  '';
  # the minted token against the GitHub stand-in: read is in scope, push is not, and after expiry nothing
  ghEnv = pkgs.buildEnv { name = "agent-runtime-ghread-env"; paths = evaluated.templates.ghread.packages; };
  ghWork = sh "agent-gh" ''
    set -u
    export PATH=${ghEnv}/bin SSL_CERT_FILE=${tn.filesystem.workspace}/ca.pem
    tok=$(cat /run/agent-runtime/credentials/token)
    call() { curl -sS --max-time 8 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $tok" "$@" https://api.test/repo; }
    echo "read: $(call)"
    echo "push: $(call -X POST)"
    while [ ! -e ${tn.filesystem.workspace}/expired ]; do sleep 0.2; done
    echo "read after expiry: $(call)"
  '';
  # the issuer and the API it mints for, one program: HMAC-signed tokens carrying scopes and expiry, a
  # revocation list, and an HTTPS endpoint that answers 200, 403 (scope) or 401 (expired, revoked, bad)
  fakeGithub = pkgs.writeText "fake-github.py" ''
    import base64, hashlib, hmac, http.server, json, os, ssl, sys, time
    STATE = "/var/lib/fake-issuer"
    KEY = open(f"{STATE}/key", "rb").read()
    DB = f"{STATE}/tokens.json"
    def load():
        try:
            return json.load(open(DB))
        except FileNotFoundError:
            return {}
    def save(d):
        json.dump(d, open(DB + ".t", "w")); os.replace(DB + ".t", DB)
    def b64(b):
        return base64.urlsafe_b64encode(b).decode().rstrip("=")
    def sign(p):
        return b64(hmac.new(KEY, p.encode(), hashlib.sha256).digest())
    def opts(args):
        return dict(zip(args[::2], args[1::2]))
    def mint(args):
        a = opts(args); caps = json.loads(a["--capabilities"]); exp = int(time.time()) + int(a["--ttl"])
        scopes = caps + (["github-push"] if os.environ.get("ISSUER_WIDEN") else [])
        payload = b64(json.dumps({"i": a["--instance"], "s": scopes, "e": exp}).encode())
        d = load(); d[a["--instance"]] = {"scopes": scopes, "exp": exp, "revoked": False, "task": a["--task"]}; save(d)
        print(json.dumps({"token": "art." + payload + "." + sign(payload), "scopes": scopes, "expires_at": exp}))
    def revoke(args):
        a = opts(args)
        if os.environ.get("ISSUER_REVOKE_FAIL"):
            sys.exit("revoke endpoint unavailable")
        tok = open(a["--token-file"]).read()
        d = load(); e = d.setdefault(a["--instance"], {}); e["revoked"] = True
        e.setdefault("revocations", []).append(hashlib.sha256(tok.encode()).hexdigest()[:16]); save(d)
    def check(tok, need):
        parts = tok.split(".")
        if len(parts) != 3 or not hmac.compare_digest(parts[2], sign(parts[1])):
            return 401, "bad token"
        c = json.loads(base64.urlsafe_b64decode(parts[1] + "=" * (-len(parts[1]) % 4)))
        if load().get(c["i"], {}).get("revoked"):
            return 401, "revoked"
        if time.time() >= c["e"]:
            return 401, "expired"
        if need not in c["s"]:
            return 403, "scope " + need + " not granted"
        return 200, "ok"
    class H(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.0"
        def answer(self, need):
            code, msg = check(self.headers.get("Authorization", "").removeprefix("Bearer "), need)
            body = msg.encode(); self.send_response(code); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
        def do_GET(self):
            self.answer("github-read")
        def do_POST(self):
            self.answer("github-push")
    if sys.argv[1] == "mint":
        mint(sys.argv[2:])
    elif sys.argv[1] == "revoke":
        revoke(sys.argv[2:])
    else:
        srv = http.server.ThreadingHTTPServer((sys.argv[2], 443), H)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain("/tmp/ca.pem", "/tmp/k.pem")
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True); srv.serve_forever()
  '';
  issuer = sh "fake-issuer" "exec ${pkgs.python3}/bin/python3 ${fakeGithub} \"$@\"";
  # an issuer that grants more than the template declares: the tool must refuse its token
  ghNoop = sh "agent-noop" "exit 0";
  issuerWide = sh "fake-issuer-wide" "ISSUER_WIDEN=1 exec ${pkgs.python3}/bin/python3 ${fakeGithub} \"$@\"";
  # the credential payload (on the non-egress `tiny` template): read it (tmpfs, read-only), print it once (to
  # exercise redaction), write a clean artifact, and optionally leak it to the output for the export-gate test
  tn = evaluated.manifestData.tiny;
  tnEnv = pkgs.buildEnv { name = "agent-runtime-tiny-env"; paths = evaluated.templates.tiny.packages; };
  credWork = sh "agent-cred" ''
    set -euo pipefail
    export PATH=${tnEnv}/bin
    t=/run/agent-runtime/credentials/token
    echo "cred_owner=$(stat -c %u:%a $t) whoami=$(id -u)"
    echo "using credential: $(cat $t)"
    if printf x > $t 2>/dev/null; then echo "FAIL credential writable"; exit 1; fi
    echo "clean result" > ${tn.filesystem.output.path}/result.txt
    cp /etc/agent-runtime/template.json ${tn.filesystem.output.path}/template.json
    (cd ${tn.filesystem.output.path} && sha256sum result.txt template.json > SHA256SUMS)
  '';
  credLeakWork = sh "agent-cred-leak" ''
    set -euo pipefail
    export PATH=${tnEnv}/bin
    cat /run/agent-runtime/credentials/token > ${tn.filesystem.output.path}/leaked.txt
    cp /etc/agent-runtime/template.json ${tn.filesystem.output.path}/template.json
    (cd ${tn.filesystem.output.path} && sha256sum leaked.txt template.json > SHA256SUMS)
  '';
in
pkgs.testers.runNixOSTest {
  name = "agent-runtime-nspawn";

  nodes.machine = {
    virtualisation.memorySize = 4096;
    virtualisation.cores = 2;
    virtualisation.diskSize = 4096;
    # assign roots the sources with nix build --out-link, which needs them registered in the VM's store;
    # the egress template's package closure must be present too (the manifest only names it as a string)
    virtualisation.additionalPaths = [
      rfProto skills runtime.tools.instance evaluated.manifestDir evaluated.hostPolicy
      (pkgs.buildEnv { name = "egress-pkgs"; paths = evaluated.templates.egress.packages; })
      (pkgs.buildEnv { name = "ghread-pkgs"; paths = evaluated.templates.ghread.packages; })
    ];
    # test-instrumentation's mkDefault 2 panics the VM on any cgroup OOM; hosts run the kernel's 0
    boot.kernel.sysctl."vm.panic_on_oom" = 0;
    # the egress subtest filters the instance veth with the tool's own nft table and routes to a non-local
    # endpoint; the node firewall and dhcpcd must not interfere, and forwarding must be on for the forward hook
    networking.firewall.enable = false;
    networking.dhcpcd.denyInterfaces = [ "ve-*" "veth-*" "dummy0" ];
    # the tool resolves the allowlist name on the host via getent; /etc/hosts is read-only on NixOS,
    # so the test's one allowed name is seeded declaratively to the dummy endpoint it serves TLS on
    networking.hosts = {
      "10.9.0.1" = [ "allowed.test" ];
      "10.9.0.2" = [ "api.test" ];
      "10.9.0.9" = [ "denied.test" ];
    };
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
    environment.systemPackages = with pkgs; [ util-linux procps gnugrep gawk coreutils jq iproute2 nftables openssl python3 dnsmasq dnsutils ];
  };

  testScript = ''
    import json, re, time
    NS = "${nsList}".split()
    I = "${tool}"
    RUST = "--template ${manifest "rust-worker-m0"} --host ${evaluated.hostPolicy}"
    TINY = "--template ${manifest "tiny"} --host ${evaluated.hostPolicy}"
    EGRESS = "--template ${manifest "egress"} --host ${evaluated.hostPolicy}"
    GH = "--template ${manifest "ghread"} --host ${evaluated.hostPolicy}"
    V = "/var/lib/agent-runtime"
    timings: dict[str, dict[str, object]] = {}

    def ms(a: int, b: int) -> int:
        return (b - a) // 1000000

    def status(i: str) -> dict:
        return json.loads(machine.succeed(f"{I} status {i}"))

    def create(i: str, tmpl: str = RUST, task: str = "") -> int:
        t = time.monotonic_ns()
        machine.succeed(f"{I} create {i} {tmpl} --task {task or 'task-' + i}")
        return ms(t, time.monotonic_ns())

    def refused(cmd: str, code: int, text: str) -> None:
        rc, out = machine.execute(f"{cmd} 2>&1")
        print(f"refused ({rc}):", out.strip()[-300:])
        assert rc == code and text in out, (cmd, rc, out)

    def run(i: str, script: str, flags: str = "") -> dict:
        machine.execute(f"{I} start {i} {flags} --wait -- {script}")
        s = status(i)
        print(f"== {i}: {s['state']}", json.dumps(s["result"]))
        print(machine.succeed(f"{I} logs {i}")[-2500:])
        return s

    def start(i: str, script: str) -> None:
        machine.succeed(f"{I} start {i} -- {script}")

    def ws(i: str) -> str:
        return f"{V}/{i}/vol/workspace/workspace"

    def destroy(i: str, flags: str = "") -> int:
        t = time.monotonic_ns()
        machine.succeed(f"{I} destroy {i} {flags}")
        took = ms(t, time.monotonic_ns())
        clean(i)
        return took

    def clean(i: str) -> None:
        machine.succeed(f"! findmnt -rn | grep -qE 'agent-runtime[-/]{i}(/| |$)'")
        machine.succeed(f"test ! -e /run/systemd/nspawn/agent-runtime-{i} -a ! -e /run/systemd/nspawn/propagate/agent-runtime-{i}")
        machine.succeed(f"! losetup -l -n -O BACK-FILE | grep -q '{V}/{i}/'")
        machine.succeed(f"! systemctl list-units --all --no-legend 'agent-runtime-{i}.service' | grep -q .")
        machine.succeed(f"! machinectl list --no-legend | grep -q 'agent-runtime-{i} '")
        machine.succeed(f"test ! -e {V}/{i} -a ! -e /run/agent-runtime/{i}")
        assert status(i)["state"] == "absent"

    def reserved() -> tuple[int, int]:
        rows = [r.split() for r in machine.succeed(f"cat {V}/*/reservation 2>/dev/null || true").split("\n") if r.strip()]
        return len(rows), sum(int(r[0]) for r in rows)

    def inventory(label: str) -> dict[str, str]:
        inv = {
            "units": machine.succeed("systemctl list-units --all --no-legend 'agent-runtime-*' | sort"),
            "mounts": machine.succeed("findmnt -rn -o TARGET,SOURCE | grep agent-runtime || true"),
            "nspawn_dirs": machine.succeed("ls -d /run/systemd/nspawn/agent-runtime-* /run/systemd/nspawn/propagate/agent-runtime-* 2>/dev/null || true"),
            "loops": machine.succeed("losetup -l -n -O NAME,BACK-FILE | grep agent-runtime || true"),
            "state": machine.succeed(f"ls {V} 2>/dev/null | grep -v '^exports$' || true"),
            # live auto roots into the state dir; a destroyed run leaves only dangling ones, which GC drops
            "gcroots": machine.succeed(f"for l in /nix/var/nix/gcroots/auto/*; do t=$(readlink \"$l\") || continue; "
                                       f"case $t in {V}/*) if [ -e \"$t\" ]; then echo \"$t -> $(readlink \"$t\")\"; fi ;; esac; done"),
            "mapped_processes": machine.succeed("ps -eo uid=,pid=,comm= | awk '$1 >= 1048576' || true"),
            "links": machine.succeed("ip -o link | awk '{print $2}' | sort | tr '\\n' ' '"),
        }
        print(f"=== inventory {label} ===")
        for k, v in inv.items():
            print(f"{k}: {v.strip() or '(none)'}")
        return inv

    def no_leaks(label: str) -> dict[str, str]:
        inv = inventory(label)
        for k in ("units", "mounts", "nspawn_dirs", "loops", "state", "gcroots", "mapped_processes"):
            assert inv[k].strip() == "", (label, k, inv[k])
        assert inv["links"] == baseline["links"], (label, inv["links"], baseline["links"])
        assert reserved() == (0, 0), (label, reserved())
        return inv

    machine.wait_for_unit("multi-user.target")
    print("=== versions ===")
    print(machine.succeed("uname -r; systemctl --version | head -1; ${pkgs.systemd}/bin/systemd-nspawn --version | head -1"))
    print("nixpkgs ${pkgs.lib.version}; rf-proto ${rfProto.rev}; skills ${skills.rev or "unpinned"}")
    print("host policy:", machine.succeed("cat ${evaluated.hostPolicy}"))
    closure = {"paths": int(machine.succeed("wc -l < ${closure}/store-paths")), "nar_bytes": int(machine.succeed("cat ${closure}/total-nar-size"))}
    print("closure:", closure)
    host_ns = {n: machine.succeed(f"readlink /proc/1/ns/{n}").strip() for n in NS}
    print("host namespaces:", host_ns)
    machine.succeed("touch /root/host-sentinel /home/host-sentinel")
    store_before = machine.succeed("ls /nix/store | wc -l; stat -c %Y /nix/store").split()
    disk_before = int(machine.succeed("df --output=avail -BM /var/lib | tail -1 | tr -dc 0-9"))
    baseline = inventory("before")
    host_pid = machine.succeed("systemd-run --unit=host-sleeper --property=Type=exec sleep 3600 >/dev/null; systemctl show -p MainPID --value host-sleeper").strip()
    shm = machine.succeed("ipcmk -M 4096 | grep -o '[0-9]*$'").strip()

    with subtest("bad instance ids are refused before anything is created"):
        for bad in ("exports", "../x", "A", "-x"):
            machine.fail(f"{I} create '{bad}' {TINY} --task t")
        assert machine.succeed(f"ls {V} 2>/dev/null | grep -v exports || true").strip() == ""

    with subtest("idle instance: create cost, start, memory overhead, teardown"):
        c = create("idle")
        print(machine.succeed("findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS | grep agent-runtime/idle; losetup -l -n"))
        t0 = time.monotonic_ns()
        s = run("idle", "${pkgs.coreutils}/bin/true", "--root")
        assert s["state"] == "succeeded", s
        timings["idle"] = {"create_ms": c, "start_to_end_ms": ms(t0, time.monotonic_ns()),
                           "memory_peak_bytes": s["result"]["memoryPeakBytes"], "runtime_us": s["result"]["runtimeUSec"],
                           "teardown_ms": destroy("idle", "--discard")}

    with subtest("concurrent reader during the start window: starting, never ambiguous; wait rides it to success"):
        # the blocking finding (wN on #152): during start's up-to-5 s leader poll state_of read ambiguous,
        # and a lock-free wait/status took it as final, failing a run that then succeeds.
        create("cwin")
        # a wait launched together with start must poll through the starting window to the real outcome
        out = machine.succeed(f"({I} start cwin -- /bin/sh -c 'sleep 1; true' >/dev/null 2>&1) & {I} wait cwin; echo rc=$?")
        assert "rc=0" in out and status("cwin")["state"] == "succeeded", out
        destroy("cwin", "--discard")
        # and a rapid sampler across a fresh start observes created/starting/running, never ambiguous
        create("cwin2")
        # rapid lock-free sampling across a whole run: start, running and the end window all read as
        # live states, never the terminal `ambiguous` (which is reserved for an outcome that never lands)
        seen = sorted(set(machine.succeed(
            f"({I} start cwin2 -- /bin/sh -c 'sleep 1; true' >/dev/null 2>&1) & "
            f"for _ in $(seq 1 200); do {I} status cwin2 | ${pkgs.jq}/bin/jq -r .state; done"
        ).split()))
        print("states observed during start:", seen)
        assert "ambiguous" not in seen, seen
        assert "starting" in seen, ("the start window was never observed as starting", seen)
        machine.succeed(f"{I} wait cwin2")
        assert status("cwin2")["state"] == "succeeded", status("cwin2")
        destroy("cwin2", "--discard")

    with subtest("probe as container root: no capabilities, namespaces recorded, read-only store and sources"):
        create("probe")
        machine.succeed(f"echo {host_pid} > {ws('probe')}/host.pid")
        s = run("probe", "${probe}", "--root")
        out = machine.succeed(f"{I} logs probe")
        assert s["state"] == "succeeded" and "FAIL" not in out, out
        guest_ns = dict(re.findall(r"^ns_(\w+): (\S+)$", out, re.M))
        shared = [n for n in NS if guest_ns[n] == host_ns[n]]
        print("namespaces shared with the host:", shared)
        assert shared == ["time"], shared
        assert s["started"]["namespaces"] == guest_ns, (s["started"]["namespaces"], guest_ns)
        assert s["started"]["uidMap"] == [0, s["uidBase"], 65536] and s["uidBase"] >= 1048576, s["started"]
        assert machine.succeed("hostname").strip() == "machine"
        machine.succeed(f"ipcs -m -i {shm}")
        machine.succeed(f"kill -0 {host_pid}")
        destroy("probe", "--discard")

    with subtest("lifecycle: concurrent instances with unique identities, policy denials, a harmless sibling teardown"):
        t0 = time.monotonic_ns()
        wall0 = int(machine.succeed("date +%s%N"))
        for i in ("job-a", "job-b"):
            timings[i] = {"create_ms": create(i)}
        refused(f"{I} create over-m {RUST} --task t", 10, '"message":"memory')
        create("hold-c", TINY)
        refused(f"{I} create over-n {TINY} --task t", 10, "instances 3 of 3")
        start("hold-c", "${hold}")
        for i in ("job-a", "job-b"):
            start(i, "${work}")
        machine.wait_until_succeeds(f"test -e {ws('hold-c')}/ready", timeout=30)
        listing = {x["id"]: x for x in json.loads(machine.succeed(f"{I} status"))}
        print("status (all):", json.dumps(listing["job-a"], indent=1))
        assert set(listing) == {"job-a", "job-b", "hold-c"}, listing
        idents = {i: (x["uidBase"], tuple(x["started"]["namespaces"][n] for n in NS if n != "time")) for i, x in listing.items()}
        print("identities:", idents)
        assert len({v[0] for v in idents.values()}) == 3, idents
        for k in range(len(NS) - 1):
            assert len({v[1][k] for v in idents.values()}) == 3, (k, idents)
        machine.succeed(f"echo {listing['job-a']['started']['leaderPid']} > {ws('hold-c')}/peer.pid")
        for i in ("job-a", "job-b"):
            s = json.loads(machine.succeed(f"{I} wait {i} --timeout-sec 300"))
            joblog = machine.succeed(f"{I} logs {i}")
            print(joblog[-1200:])
            assert s["state"] == "succeeded" and s["result"]["exitStatus"] == 0, s
            assert re.search(r"test result: ok\. \d+ passed", joblog)
            assert re.search(r"^status: CapEff: 0+ CapBnd: 0+ NoNewPrivs: 1 Seccomp: 2\s*$", joblog, re.M), "agent kept privileges"
            marks = re.search(r"started_ns=(\d+).*finished_ns=(\d+)", joblog, re.S)
            assert marks
            timings[i].update({"startup_ms": (int(marks.group(1)) - wall0) // 1000000,
                               "work_ms": (int(marks.group(2)) - int(marks.group(1))) // 1000000,
                               "memory_peak_bytes": s["result"]["memoryPeakBytes"], "cpu_ns": s["result"]["cpuUsageNSec"],
                               "disk_bytes": int(machine.succeed(f"du -sbx {V}/{i}/vol/* | awk '{{s+=$1}} END {{print s}}'"))})
            machine.succeed(f"{I} export {i}")
            e = f"{V}/exports/{i}"
            bundle = json.loads(machine.succeed(f"cat {e}/bundle.json"))
            print(i, "bundle:", json.dumps({k: bundle[k] for k in ("outcome", "recovery", "log", "omittedPatches")}), [f["path"] for f in bundle["files"]])
            assert bundle["outcome"] == "succeeded" and not bundle["recovery"]
            meta = json.loads(machine.succeed(f"cat {e}/sources/rf-proto.json"))
            print("changed", meta["changedPaths"], "dropped", meta["droppedPaths"][:5])
            assert "README.md" in meta["changedPaths"] and "untracked-artifact.bin" in meta["changedPaths"], meta
            machine.succeed(f"grep -q 'GIT binary patch' {e}/sources/rf-proto.patch")
            machine.succeed(f"grep -q 'edited by {i}' {e}/sources/rf-proto.patch")
            machine.succeed(f"cd {e}/output && sha256sum -c SHA256SUMS")
            machine.succeed(f"grep -q 'test result: ok' {e}/run.log")
            machine.succeed(f"cd {e} && jq -r '.files[] | select(.path != \"bundle.json\") | \"\\(.sha256)  \\(.path)\"' bundle.json | sha256sum -c --quiet")
            timings[i]["export_bytes"] = int(machine.succeed(f"du -sb {e} | cut -f1"))
        live = inventory("three live, two finished")
        assert f"{V}/job-a/run/gcroots/rf-proto -> ${rust.src.locked.storePath}" in live["gcroots"], live["gcroots"]
        timings["job-a"]["teardown_ms"] = destroy("job-a")
        assert status("hold-c")["state"] == "running", "a sibling's teardown disturbed hold-c"
        machine.succeed(f"touch {ws('hold-c')}/go")
        s = json.loads(machine.succeed(f"{I} wait hold-c --timeout-sec 30"))
        print(machine.succeed(f"{I} logs hold-c"))
        assert s["state"] == "succeeded", s
        machine.succeed(f"{I} export hold-c")
        timings["job-b"]["teardown_ms"] = destroy("job-b")
        destroy("hold-c")
        timings["lifecycle"] = {"total_ms": ms(t0, time.monotonic_ns())}

    with subtest("idempotent duplicates: create, start, cancel, export, destroy"):
        create("dup", TINY, "task-dup")
        machine.succeed(f"{I} create dup {TINY} --task task-dup")
        refused(f"{I} create dup {TINY} --task another", 12, "another task")
        s = run("dup", "${pkgs.coreutils}/bin/true")
        inv = s["started"]["invocation"]
        machine.succeed(f"{I} start dup -- ${marker}")
        assert status("dup")["started"]["invocation"] == inv, "a second start re-ran the instance"
        machine.succeed(f"test ! -e {ws('dup')}/payload-ran")
        machine.succeed(f"{I} cancel dup; {I} cancel dup")
        assert status("dup")["state"] == "succeeded"
        machine.succeed(f"{I} export dup")
        first = machine.succeed(f"cat {V}/dup/exported.json")
        machine.succeed(f"{I} export dup")
        assert machine.succeed(f"cat {V}/dup/exported.json") == first
        destroy("dup")
        machine.succeed(f"{I} destroy dup")

    with subtest("cancellation: a running instance stops as cancelled; export is a recovery bundle"):
        create("cancel", TINY)
        start("cancel", "${sleeper}")
        machine.wait_until_succeeds(f"test -e {ws('cancel')}/ready", timeout=30)
        refused(f"{I} destroy cancel", 12, "cancel it first")
        machine.succeed(f"{I} cancel cancel; {I} cancel cancel")
        assert status("cancel")["state"] == "cancelled"
        refused(f"{I} destroy cancel", 12, "has not been exported")
        machine.succeed(f"{I} export cancel")
        assert json.loads(machine.succeed(f"cat {V}/exports/cancel/bundle.json"))["recovery"]
        destroy("cancel")

    with subtest("timeout: the unit's runtime limit ends the run as timed-out"):
        create("timeout", TINY)
        s = run("timeout", "${sleeper}", "--timeout-sec 3")
        assert s["state"] == "timed-out", s
        destroy("timeout", "--discard")

    with subtest("crash mid-run: SIGKILL of the instance's nspawn is a failed outcome, torn down clean"):
        create("killed", TINY)
        start("killed", "${sleeper}")
        machine.wait_until_succeeds(f"test -e {ws('killed')}/ready", timeout=30)
        machine.succeed("kill -9 $(systemctl show -p MainPID --value agent-runtime-killed.service)")
        s = json.loads(machine.execute(f"{I} wait killed --timeout-sec 30")[1])
        print(json.dumps(s["result"]))
        assert s["state"] == "failed" and s["result"]["serviceResult"] == "signal", s
        machine.succeed(f"{I} export killed")
        destroy("killed")

    with subtest("supervisor crash: killing the waiting CLI does not lose the outcome"):
        create("sup", TINY)
        machine.succeed(f"{I} start sup --wait -- ${sleeper} > /tmp/sup.out 2>&1 & echo $! > /tmp/sup.pid")
        # start execs wait in the same process once the unit runs
        machine.wait_until_succeeds("tr '\\0' ' ' < /proc/$(cat /tmp/sup.pid)/cmdline | grep -q ' wait sup'", timeout=30)
        machine.succeed("kill -9 $(cat /tmp/sup.pid)")
        assert status("sup")["state"] == "running"
        machine.succeed(f"{I} cancel sup")
        s = status("sup")
        assert s["state"] == "cancelled" and s["result"]["serviceResult"] != "", s
        machine.succeed(f"{I} export sup")
        destroy("sup")

    with subtest("killed create: reconcile rolls back what a SIGKILLed create left"):
        machine.succeed(f"({I} create kc {RUST} --task t > /dev/null 2>&1 & pid=$!; "
                        f"while [ ! -e {V}/kc/reservation ]; do sleep 0.002; done; kill -9 $pid)")
        time.sleep(3)
        print("after SIGKILL:", machine.succeed(f"ls -a {V}/kc; {I} status kc"))
        assert status("kc")["state"] == "incomplete"
        refused(f"{I} create kc {RUST} --task t", 12, "incomplete")
        rec = json.loads(machine.succeed(f"{I} reconcile"))
        print("reconcile:", rec)
        assert {"id": "kc", "state": "rolled-back", "reason": "create never finished"} in rec, rec
        clean("kc")

    with subtest("admission: disk refuses oversubscription"):
        free = int(machine.succeed(f"df --output=avail -BM {V} | tail -1 | tr -dc 0-9"))
        machine.succeed(f"fallocate -l {free - ${toString hostPolicy.reserve.diskMiB} - 100}M /var/lib/ballast")
        refused(f"{I} create adm-d {RUST} --task t", 10, '"message":"disk')
        create("adm-t", TINY)
        destroy("adm-t", "--discard")
        machine.succeed("rm /var/lib/ballast")

    with subtest("fail closed: no user namespace, no payload"):
        create("nouserns", TINY)
        userns_max = machine.succeed("cat /proc/sys/user/max_user_namespaces").strip()
        machine.succeed("sysctl -w user.max_user_namespaces=0")
        s = run("nouserns", "${marker}")
        machine.succeed(f"sysctl -w user.max_user_namespaces={userns_max}")
        assert "Failed to fork inner child" in machine.succeed(f"{I} logs nouserns")
        assert s["state"] == "failed", s
        machine.succeed(f"test ! -e {ws('nouserns')}/payload-ran")
        assert reserved()[0] == 1
        destroy("nouserns", "--discard")

    with subtest("failed teardown keeps the reservation; a second destroy releases it"):
        create("busy", TINY)
        machine.succeed(f"systemd-run --unit=holder --property=Type=exec --working-directory={V}/busy/vol/workspace sleep 600")
        refused(f"{I} destroy busy", 1, "is busy")
        assert reserved() == (1, 64), reserved()
        machine.succeed("systemctl stop holder")
        destroy("busy")

    with subtest("budget: tasksMax holds a fork bomb"):
        create("pids")
        start("pids", "${forkbomb}")
        cg = "/sys/fs/cgroup/system.slice/agent-runtime-pids.service"
        machine.wait_until_succeeds(f"awk '$1 == \"max\" && $2 > 0' {cg}/pids.events | grep -q .", timeout=120)
        tasks = int(machine.succeed(f"cat {cg}/pids.current"))
        print("pids.current", tasks, "pids.max", machine.succeed(f"cat {cg}/pids.max").strip(), machine.succeed(f"cat {cg}/pids.events").strip())
        assert tasks <= ${toString rust.t.resources.tasksMax}, tasks
        s = json.loads(machine.execute(f"{I} wait pids --timeout-sec 120")[1])
        timings["pids"] = {"pids_current": tasks, "state": s["state"], "teardown_ms": destroy("pids", "--discard")}

    with subtest("budget: memoryMiB ends a memory hog as oom-killed; the recovery bundle is kept"):
        create("oom")
        s = run("oom", "${hog}")
        assert s["state"] == "oom-killed", s
        machine.succeed(f"{I} export oom")
        b = json.loads(machine.succeed(f"cat {V}/exports/oom/bundle.json"))
        assert b["recovery"] and b["outcome"] == "oom-killed", b
        timings["oom"] = {"memory_peak_bytes": s["result"]["memoryPeakBytes"], "teardown_ms": destroy("oom")}

    with subtest("budget: cpus caps three busy loops at one core"):
        create("cpu")
        s = run("cpu", "${spin}")
        runtime_s, cpu_s = s["result"]["runtimeUSec"] / 1e6, s["result"]["cpuUsageNSec"] / 1e9
        print("runtime", runtime_s, "cpu", cpu_s)
        assert cpu_s <= runtime_s * ${toString rust.t.resources.cpus} * 1.15, (runtime_s, cpu_s)
        timings["cpu"] = {"runtime_s": runtime_s, "cpu_s": cpu_s, "teardown_ms": destroy("cpu", "--discard")}

    with subtest("budget: bytes and inodes run out inside the instance, not on the host"):
        create("fill")
        before = int(machine.succeed("df --output=avail -BM /var/lib | tail -1 | tr -dc 0-9"))
        s = run("fill", "${fill}")
        out = machine.succeed(f"{I} logs fill")
        assert s["state"] == "failed" and s["result"]["exitStatus"] == 3, s
        assert re.search(r"dd_exit=1\n.*No space left on device", out), out
        assert re.search(r"touch_exit=[1-9]\d*\n.*No space left on device", out), out
        after = int(machine.succeed("df --output=avail -BM /var/lib | tail -1 | tr -dc 0-9"))
        assert after >= before - 2, (before, after)
        timings["fill"] = {"host_disk_delta_mib": after - before, "teardown_ms": destroy("fill", "--discard")}

    with subtest("host reboot: an interrupted run is ambiguous and not replayed; a created one still starts"):
        no_leaks("after every pre-reboot subtest")
        create("reboot-run", TINY)
        create("reboot-new", TINY)
        start("reboot-run", "${sleeper}")
        machine.wait_until_succeeds(f"test -e {ws('reboot-run')}/ready", timeout=30)
        inventory("before the crash")
        machine.crash()
        machine.start()
        machine.wait_for_unit("multi-user.target")
        inventory("after the reboot")
        store_now = machine.succeed("ls /nix/store | wc -l; stat -c %Y /nix/store").split()
        # the VM's writable store overlay is recreated at boot: same entries, a new mtime
        assert store_now[0] == store_before[0], (store_before, store_now)
        store_before = store_now
        rec = {r["id"]: r["state"] for r in json.loads(machine.succeed(f"{I} reconcile"))}
        print("reconcile after reboot:", rec)
        assert rec == {"reboot-run": "ambiguous", "reboot-new": "created"}, rec
        refused(f"{I} start reboot-run -- ${marker}", 11, "not replayed")
        assert reserved() == (2, 128), reserved()
        s = run("reboot-new", "${pkgs.coreutils}/bin/true")
        assert s["state"] == "succeeded", s
        machine.succeed(f"{I} export reboot-run")
        assert json.loads(machine.succeed(f"cat {V}/exports/reboot-run/bundle.json"))["outcome"] == "ambiguous"
        destroy("reboot-run")
        destroy("reboot-new", "--discard")

    with subtest("per-run credential: tmpfs delivery, redaction, export leak-gate, cross-instance isolation"):
        secret = "glpat-REDACTME-" + "0123456789abcdef"
        machine.succeed(f"umask 077; printf %s {secret} > /tmp/cred")
        machine.succeed(f"{I} create crd {TINY} --task sammasak/x#1")
        machine.succeed(f"{I} start crd --credential /tmp/cred --wait -- ${credWork}")
        assert status("crd")["state"] == "succeeded", status("crd")
        # the payload's stdout lands in the journal; read it back through `logs` (the --wait
        # stdout carries the status JSON, not the run's output)
        out = machine.succeed(f"{I} logs crd")
        print(out)
        assert "cred_owner=1000:400" in out and "FAIL credential writable" not in out, out
        # the printed log is redacted: the tool reads the still-mounted tmpfs secret and masks it
        assert secret not in out, "credential leaked unredacted into the logs view"
        # the credential lives on tmpfs under /run, never on the persistent /var/lib state
        machine.succeed(f"test -e /run/agent-runtime/crd/cred/token -a ! -e {V}/crd/cred")
        machine.succeed(f"! grep -rqF {secret} {V}/crd 2>/dev/null")  # not at rest in persistent state
        machine.succeed(f"! grep -rqF {secret} /nix/store/*agent-runtime* 2>/dev/null")  # not in the store
        print(machine.succeed(f"{I} export crd"))
        machine.succeed(f"! grep -rqF {secret} {V}/exports/crd")
        machine.succeed(f"{I} destroy crd --discard"); clean("crd")
        # a payload that leaks the secret to its output: export refuses (credential class, exit 5), caller re-passes nothing
        machine.succeed(f"{I} create crl {TINY} --task sammasak/x#2")
        machine.succeed(f"{I} start crl --credential /tmp/cred --wait -- ${credLeakWork}")
        rc, out = machine.execute(f"{I} export crl 2>&1")
        print("export of a leaking run:", rc, out.strip()[-160:])
        assert rc == 5 and "credential appears in an exported artifact" in out, (rc, out)
        machine.succeed(f"{I} destroy crl --discard"); clean("crl")

    with subtest("credentials: two instances at once, each denied the other's"):
        for i, t in (("ca", "token-a-0123456789abcdef"), ("cb", "token-b-fedcba9876543210")):
            machine.succeed(f"umask 077; printf %s {t} > /tmp/cred-{i}")
            machine.succeed(f"{I} create {i} {TINY} --task sammasak/x#5")
            machine.succeed(f"{I} start {i} --credential /tmp/cred-{i} -- ${credPeer}")
        machine.wait_until_succeeds(f"test -e {V}/ca/vol/workspace/workspace/ready -a -e {V}/cb/vol/workspace/workspace/ready", timeout=30)
        assert status("ca")["state"] == "running" and status("cb")["state"] == "running", "not both running at once"
        for i, peer in (("ca", "cb"), ("cb", "ca")):
            machine.succeed(f"echo {peer} > {V}/{i}/vol/workspace/workspace/peer")
            machine.succeed(f"test -e /run/agent-runtime/{peer}/cred/token")  # the peer's token exists on the host
        for i in ("ca", "cb"):
            machine.succeed(f"touch {V}/{i}/vol/workspace/workspace/go")
        for i, own, other in (("ca", "token-a-0123456789abcdef", "token-b-fedcba9876543210"), ("cb", "token-b-fedcba9876543210", "token-a-0123456789abcdef")):
            machine.wait_until_succeeds(f"{I} status {i} | jq -e '.state == \"succeeded\"'", timeout=60)
            out = machine.succeed(f"{I} logs {i}")
            print(i, out)
            import hashlib
            assert f"own: {hashlib.sha256(own.encode()).hexdigest()[:16]}" in out and "its token is not readable from here" in out, out
            assert other not in out and own not in out, out
            machine.succeed(f"{I} destroy {i} --discard"); clean(i)

    with subtest("minimal egress: the allowlisted name over DNS+TLS; local and routed-off-host denied"):
        # endpoints that exist before the instance: 10.9.0.1 allowed (host /etc/hosts maps the name), 10.9.0.9 denied-local;
        # 10.8.0.5 is in a netns reachable only by the host routing (the forward hook must drop it, not the input hook)
        machine.succeed("ip link add dummy0 type dummy && ip addr add 10.9.0.1/24 dev dummy0 && ip addr add 10.9.0.9/24 dev dummy0 && ip link set dummy0 up")
        machine.succeed("ip netns add ep && ip link add veth-h type veth peer name veth-e && ip link set veth-e netns ep")
        machine.succeed("ip addr add 10.8.0.1/24 dev veth-h && ip link set veth-h up")
        machine.succeed("ip -n ep addr add 10.8.0.5/24 dev veth-e && ip -n ep link set veth-e up && ip -n ep link set lo up && ip -n ep route add default via 10.8.0.1")
        # allowed.test -> 10.9.0.1 is seeded declaratively in networking.hosts (the tool resolves via getent)
        machine.succeed("cd /tmp && openssl req -x509 -newkey rsa:2048 -nodes -keyout k.pem -out ca.pem -days 1 "
                        "-subj /CN=allowed.test -addext 'subjectAltName=DNS:allowed.test,DNS:api.test,IP:10.9.0.1,IP:10.9.0.2,IP:10.9.0.9,IP:10.8.0.5' >/dev/null 2>&1")
        machine.succeed("systemd-run --unit=tls-local ${pkgs.python3}/bin/python3 ${tlsEndpoint} 0.0.0.0")
        # systemd-run must wrap `ip netns exec` (not the reverse): the transient unit otherwise lands in the
        # root netns and binds nothing, while the endpoint IP only exists inside ep. python3 needs its absolute
        # path -- the transient unit's PATH does not carry /run/current-system/sw/bin into `ip netns exec`.
        machine.succeed("systemd-run --unit=tls-ep ip netns exec ep ${pkgs.python3}/bin/python3 ${tlsEndpoint} 10.8.0.5")
        # two resolvers that answer the host, one local and one routed off it: the instance must get neither
        machine.succeed("systemd-run --unit=dns-local ${pkgs.dnsmasq}/bin/dnsmasq -k --listen-address=10.9.0.1 --bind-interfaces --no-resolv --address=/allowed.test/10.9.0.1 --address=/denied.test/10.9.0.9")
        machine.succeed("systemd-run --unit=dns-ep ip netns exec ep ${pkgs.dnsmasq}/bin/dnsmasq -k --listen-address=10.8.0.5 --bind-interfaces --no-resolv --address=/allowed.test/10.9.0.1")
        for r in ("10.9.0.1", "10.8.0.5"):
            machine.wait_until_succeeds(f"dig +time=2 +tries=1 +short @{r} allowed.test | grep -q 10.9.0.1", timeout=20)  # the host gets answers
        machine.wait_until_succeeds("curl -sS --max-time 5 --cacert /tmp/ca.pem https://10.9.0.1/ | grep -q endpoint-ok", timeout=20)
        machine.wait_until_succeeds("curl -sS --max-time 5 -k https://10.8.0.5/ | grep -q endpoint-ok", timeout=20)  # host CAN route to it
        machine.succeed(f"{I} create egr {EGRESS} --task sammasak/egress#1")
        machine.succeed(f"cp /tmp/ca.pem {V}/egr/vol/workspace/workspace/ca.pem")
        machine.succeed(f"{I} start egr --wait -- ${egWork}")
        assert status("egr")["state"] == "succeeded", status("egr")
        # the payload's stdout lands in the journal; read it back through `logs`
        out = machine.succeed(f"{I} logs egr")
        print(out)
        assert re.search(r"allowed: rc=0 body=\[endpoint-ok\]", out), "the allowlisted host was not reached"
        assert re.search(r"denied-local: REFUSED", out), "a non-allowlisted local IP was reachable"
        assert re.search(r"denied-routed: REFUSED", out), "a routed-off-host IP was reachable (forward hook hole)"
        assert re.search(r"pinned-name: rc=0 10\.9\.0\.1", out), "the pinned allowlist name did not resolve (the denied check would prove nothing)"
        assert re.search(r"denied-name: rc=2 \[\]", out), "a non-allowlisted name resolved"
        assert "raw-dns 10.9.0.1: REFUSED" in out and "raw-dns 10.8.0.5: REFUSED" in out, "a raw DNS query got an answer"
        machine.succeed(f"{I} export egr || true; {I} destroy egr --discard"); clean("egr")
        machine.succeed("! nft list tables 2>/dev/null | grep -q art_egr")  # the allowlist table is gone

    with subtest("two egress instances started at once: each filter on its own container's veth, both work"):
        for i in ("eg1", "eg2"):
            machine.succeed(f"{I} create {i} {EGRESS} --task sammasak/egress#2")
            machine.succeed(f"cp /tmp/ca.pem {V}/{i}/vol/workspace/workspace/ca.pem")
            machine.succeed(f"touch {V}/{i}/vol/workspace/workspace/hold")
        # both starts in flight together: the veth each takes is its own container's peer, not a link diff
        machine.succeed(f"({I} start eg1 --wait -- ${egWork} > /tmp/eg1.out 2>&1 &); ({I} start eg2 --wait -- ${egWork} > /tmp/eg2.out 2>&1 &)")
        # while both run: the veth in each instance's nft table must be the host end of that instance's own
        # host0 (host0@ifN, N the host-side index), so a swap between the two fails here
        for i in ("eg1", "eg2"):
            machine.wait_until_succeeds(f"{I} logs {i} | grep -q '^held'", timeout=120)
        for i in ("eg1", "eg2"):
            leader = status(i)["started"]["leaderPid"]
            filtered = sorted(set(re.findall(r'iifname "([^"]+)"', machine.succeed(f"nft list table inet art_{i}"))))
            assert len(filtered) == 1, (i, filtered)
            host_index = machine.succeed(f"ip -o link show {filtered[0]}").split(":")[0]
            inner = machine.succeed(f"nsenter -t {leader} -n ip -o link show host0")
            peer = re.search(r"host0@if(\d+)", inner)
            assert peer, inner
            print(f"pairing {i}: leader {leader} host0@if{peer.group(1)}, filtered {filtered[0]} index {host_index}")
            assert peer.group(1) == host_index, (i, "filters a veth that is not its own", peer.group(1), host_index)
        for i in ("eg1", "eg2"):
            machine.succeed(f"touch {V}/{i}/vol/workspace/workspace/release")
        machine.wait_until_succeeds(f"{I} status eg1 | jq -e '.state == \"succeeded\"' && {I} status eg2 | jq -e '.state == \"succeeded\"'", timeout=120)
        veths = {}
        for i in ("eg1", "eg2"):
            out = machine.succeed(f"{I} logs {i}")
            assert re.search(r"allowed: rc=0 body=\[endpoint-ok\]", out) and "denied-routed: REFUSED" in out, (i, out)
            veths[i] = sorted(set(re.findall(r'iifname "([^"]+)"', machine.succeed(f"nft list table inet art_{i}"))))
        print("filtered veths:", veths)
        assert len(veths["eg1"]) == 1 and len(veths["eg2"]) == 1 and veths["eg1"] != veths["eg2"], veths
        for i in ("eg1", "eg2"):
            machine.succeed(f"{I} destroy {i} --discard"); clean(i)
            machine.succeed(f"! nft list tables 2>/dev/null | grep -q art_{i}")

    with subtest("minted credential: scoped to the template's capability, expiring, revoked at teardown"):
        machine.succeed("mkdir -p /var/lib/fake-issuer && head -c 32 /dev/urandom > /var/lib/fake-issuer/key")
        machine.succeed("ip addr add 10.9.0.2/24 dev dummy0")
        # the egress subtests' endpoint listens on 0.0.0.0:443 (so a denied address had a live listener); it is done
        machine.succeed("systemctl stop tls-local")
        machine.succeed("systemd-run --unit=fake-github ${pkgs.python3}/bin/python3 ${fakeGithub} serve 10.9.0.2")
        machine.wait_until_succeeds("curl -sS --max-time 5 --cacert /tmp/ca.pem -o /dev/null -w '%{http_code}' https://api.test/repo | grep -q 401", timeout=20)
        # an issuer that grants more than the template declares is refused before anything runs
        machine.succeed(f"{I} create ghw {GH} --task sammasak/x#3")
        rc, out = machine.execute(f"{I} start ghw --credential-issuer ${issuerWide} --wait -- ${ghWork} 2>&1")
        print("issuer granting github-push to a github-read template:", rc, out.strip()[-220:])
        assert rc == 5 and "not within the template's capabilities" in out and status("ghw")["state"] == "created", (rc, out)
        db = json.loads(machine.succeed("cat /var/lib/fake-issuer/tokens.json"))
        print("issuer after the refusal:", db["ghw"])
        assert db["ghw"]["revoked"] and len(db["ghw"]["revocations"]) == 1, ("the refused token was not revoked", db["ghw"])
        machine.succeed(f"test ! -e /run/agent-runtime/ghw/refused-token -a ! -e {V}/ghw/cred-issuer")
        rc, out = machine.execute(f"{I} start ghw --credential-issuer ${issuer} --credential-ttl 99999 -- ${ghWork} 2>&1")
        assert rc == 2 and "never outlives the run" in out, (rc, out)
        machine.succeed(f"{I} destroy ghw --discard"); clean("ghw")
        # the real run: a 6 s token, github-read only
        machine.succeed(f"{I} create gh {GH} --task sammasak/x#4")
        machine.succeed(f"cp /tmp/ca.pem {V}/gh/vol/workspace/workspace/ca.pem")
        machine.succeed(f"{I} start gh --credential-issuer ${issuer} --credential-ttl 6 -- ${ghWork}")
        st = status("gh")
        cred = st["started"]["credential"]
        print("credential record:", json.dumps(cred))
        assert cred["kind"] == "minted" and cred["scopes"] == ["github-read"] and cred["expiresAt"] > time.time(), cred
        assert "art." not in json.dumps(st), "the token is in the instance record"
        machine.wait_until_succeeds(f"{I} logs gh | grep -q '^push: '", timeout=60)
        machine.succeed(f"w=$(( {cred['expiresAt']} - $(date +%s) + 1 )); [ $w -le 0 ] || sleep $w; touch {V}/gh/vol/workspace/workspace/expired")
        machine.wait_until_succeeds(f"{I} status gh | jq -e '.state == \"succeeded\"'", timeout=60)
        out = machine.succeed(f"{I} logs gh")
        print(out)
        assert "read: 200" in out and "push: 403" in out and "read after expiry: 401" in out, out
        db = json.loads(machine.succeed("cat /var/lib/fake-issuer/tokens.json"))
        assert db["gh"]["scopes"] == ["github-read"] and db["gh"]["task"] == "sammasak/x#4" and not db["gh"]["revoked"], db
        machine.succeed(f"{I} export gh")
        machine.succeed(f"{I} destroy gh"); clean("gh")
        db = json.loads(machine.succeed("cat /var/lib/fake-issuer/tokens.json"))
        print("issuer after destroy:", db["gh"])
        assert db["gh"]["revoked"], "teardown did not revoke the minted token"

    with subtest("minted credential: a relative issuer path is made absolute; a failed revoke is reported, not hidden"):
        machine.succeed("mkdir -p /tmp/iss && cp ${issuer} /tmp/iss/fake-issuer && chmod 0755 /tmp/iss/fake-issuer")
        machine.succeed(f"{I} create ghr {GH} --task sammasak/x#5")
        machine.succeed(f"cd /tmp/iss && {I} start ghr --credential-issuer ./fake-issuer --wait -- ${ghNoop}")
        cred = status("ghr")["started"]["credential"]
        assert cred["issuer"] == "/tmp/iss/fake-issuer", cred
        machine.succeed(f"cd / && {I} destroy ghr --discard"); clean("ghr")  # teardown runs from another directory
        db = json.loads(machine.succeed("cat /var/lib/fake-issuer/tokens.json"))
        assert db["ghr"]["revoked"], ("a relative issuer path was not revoked from another directory", db["ghr"])
        machine.succeed(f"{I} create ghf {GH} --task sammasak/x#6")
        machine.succeed(f"{I} start ghf --credential-issuer ${issuer} --wait -- ${ghNoop}")
        tok = machine.succeed("cat /run/agent-runtime/ghf/cred/token")
        rc, out = machine.execute(f"ISSUER_REVOKE_FAIL=1 {I} destroy ghf --discard 2>&1 >/dev/null")
        print("destroy with a failing revoke:", rc, out.strip())
        assert rc == 0 and "revoking the minted token at the issuer failed" in out and "revoke endpoint unavailable" in out, (rc, out)
        assert tok not in out, "the token is in the warning"
        clean("ghf")
        db = json.loads(machine.succeed("cat /var/lib/fake-issuer/tokens.json"))
        assert not db["ghf"]["revoked"], db["ghf"]

    with subtest("retried start: a stale minted record is revoked and dropped; the operator's token never goes to revoke"):
        import hashlib
        machine.succeed(f"{I} create grt {GH} --task sammasak/x#7")
        # what a start leaves when it dies after minting and before its marker: the token on tmpfs, the issuer
        # record, state still `created`
        old = json.loads(machine.succeed("${issuer} mint --instance grt --task sammasak/x#7 --capabilities '[\"github-read\"]' --ttl 60"))["token"]
        machine.succeed(f"mkdir -p /run/agent-runtime/grt/cred && (umask 077; printf %s '{old}' > /run/agent-runtime/grt/cred/token)")
        machine.succeed(f"echo ${issuer} > {V}/grt/cred-issuer")
        assert status("grt")["state"] == "created"
        op = "operator-token-0123456789abcdef"
        machine.succeed(f"umask 077; printf %s {op} > /tmp/cred-op")
        machine.succeed(f"{I} start grt --credential /tmp/cred-op --wait -- ${ghNoop}")
        assert status("grt")["started"]["credential"]["kind"] == "file"
        machine.succeed(f"test ! -e {V}/grt/cred-issuer")
        sha = lambda t: hashlib.sha256(t.encode()).hexdigest()[:16]
        db = json.loads(machine.succeed("cat /var/lib/fake-issuer/tokens.json"))
        print("issuer after the retried start:", db["grt"])
        assert db["grt"]["revocations"] == [sha(old)], ("the stale minted token was not revoked", db["grt"])
        machine.succeed(f"{I} destroy grt --discard"); clean("grt")
        db = json.loads(machine.succeed("cat /var/lib/fake-issuer/tokens.json"))
        print("issuer after destroy:", db["grt"])
        assert db["grt"]["revocations"] == [sha(old)] and sha(op) not in db["grt"]["revocations"], ("the operator token went to revoke", db["grt"])
        machine.succeed("for u in tls-ep dns-local dns-ep fake-github; do systemctl stop $u || true; done; ip netns del ep; ip link del dummy0")

    with subtest("host unchanged, nothing left behind"):
        no_leaks("after")
        store_after = machine.succeed("ls /nix/store | wc -l; stat -c %Y /nix/store").split()
        assert store_before == store_after, (store_before, store_after)
        machine.succeed("test -f /root/host-sentinel -a -f /home/host-sentinel")
        disk_after = int(machine.succeed("df --output=avail -BM /var/lib | tail -1 | tr -dc 0-9"))
        exports = int(machine.succeed(f"du -sm {V}/exports | cut -f1"))
        print("host disk before", disk_before, "after", disk_after, "exports MiB", exports)
        assert disk_after >= disk_before - exports - 16, (disk_before, disk_after, exports)
        print("exports kept:", machine.succeed(f"ls {V}/exports").split())

    print("=== measurements ===")
    print(json.dumps({"closure": closure, "shared_namespaces": shared, "timings": timings}, indent=2))
  '';
}
