# Proof for the ephemeral nspawn agent runtime (#135 M0, #137 M1 enforcement):
# templates declared through the typed module (#134) materialised as
# user-namespaced systemd-nspawn instances by a transient-unit factory, never by
# a host switch or a static containers.<name> entry. Every writable mount is its
# own fixed-size ext4 image, and create admits an instance only against the host
# policy. Runs only in QEMU:
# nix build .#packages.x86_64-linux.agent-runtime-nspawn
{ pkgs, lib, rfProto, skills }:
let
  runtime = import ../modules/agent-runtime/lib.nix { inherit lib pkgs; };
  evaluated = runtime.evalManifests {
    modules = [
      {
        sam.agentRuntime.host = {
          enable = true;
          eligibleTemplates = [ "rust-worker-m0" "tiny" ];
          maxConcurrentInstances = 3;
          reserve = { memoryMiB = 2600; diskMiB = 512; };
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
          packages = with pkgs; [ bash coreutils ];
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
  nsList = "user mnt pid ipc uts net cgroup time";
  # nspawn's default bounding set minus SETUID, SETGID and SETPCAP, which setpriv
  # needs to switch user and empty the bounding set before the payload runs
  dropCaps = lib.concatStringsSep "," [
    "CAP_CHOWN" "CAP_DAC_OVERRIDE" "CAP_DAC_READ_SEARCH" "CAP_FOWNER" "CAP_FSETID" "CAP_KILL"
    "CAP_LINUX_IMMUTABLE" "CAP_NET_BIND_SERVICE" "CAP_NET_BROADCAST" "CAP_NET_ADMIN" "CAP_NET_RAW"
    "CAP_IPC_OWNER" "CAP_SYS_CHROOT" "CAP_SYS_PTRACE" "CAP_SYS_ADMIN" "CAP_SYS_BOOT" "CAP_SYS_NICE"
    "CAP_SYS_RESOURCE" "CAP_SYS_TTY_CONFIG" "CAP_MKNOD" "CAP_LEASE" "CAP_AUDIT_WRITE"
    "CAP_AUDIT_CONTROL" "CAP_SETFCAP"
  ];

  # One factory per template; admission state (reservations, UID slots) is shared.
  mkFactory =
    name:
    let
      t = evaluated.templates.${name};
      m = evaluated.manifestData.${name};
      fs = m.filesystem;
      manifestFile = "${evaluated.manifestDir}/${name}.json";
      volumes = {
        workspace = { path = fs.workspace; inherit (fs.workspaceBudget) sizeMiB inodes; mode = "0755"; owner = 1000; };
        home = fs.home // { mode = "0700"; owner = 1000; };
        cache = fs.cache // { mode = "0700"; owner = 1000; };
        output = fs.output // { mode = "0755"; owner = 1000; };
        tmp = fs.tmp // { mode = "1777"; owner = 0; };
      };
      diskMiB = lib.foldl' (s: v: s + v.sizeMiB) 0 (lib.attrValues volumes);
      sourceBinds = lib.concatMapStrings (s: ''--bind-ro="${s.locked.storePath}:/src/${baseNameOf s.path}$opt" '') (lib.attrValues m.sources);
      skillBinds = lib.concatStrings (lib.mapAttrsToList (n: s: ''--bind-ro="${s.path}:/skills/${n}$opt" '') m.skills.names);
    in
    pkgs.writeShellScript "agent-runtime-${name}" ''
      set -euo pipefail
      export PATH=${lib.makeBinPath (with pkgs; [ bash coreutils diffutils gawk gnugrep gnused findutils util-linux procps systemd e2fsprogs ])}
      cmd=$1; id=$2; shift 2
      state=/var/lib/agent-runtime
      base=$state/$id
      root=/run/agent-runtime/$id/root
      refuse() { echo "admission refused: $*" >&2; exit 75; }
      reservations() { cat "$state"/*/reservation 2>/dev/null || true; }
      teardown() {
        systemctl stop "agent-runtime-$id.service" 2>/dev/null || true
        systemctl reset-failed "agent-runtime-$id.service" 2>/dev/null || true
        if mountpoint -q "$root"; then umount -R "$root"; fi
        for v in "$base"/mnt/*; do
          if mountpoint -q "$v"; then umount "$v"; fi
        done
        rm -rf --one-file-system "/run/agent-runtime/$id" "$base/mnt" "$base/img" "$base/cred" "$base/uidbase"
        # the reservation goes last: a teardown that fails above keeps the instance counted
        rm -f "$base/reservation"
        rmdir "$base"
      }
      case $cmd in
        create)
          [[ $id =~ ^[a-z0-9]([a-z0-9-]{0,40}[a-z0-9])?$ ]] && [ "$id" != exports ] || { echo "bad instance id: $id" >&2; exit 64; }
          mkdir -p "$state" /run/agent-runtime
          exec 9>/run/agent-runtime/.admission.lock; flock 9
          [ ! -e "$base" ] || { echo "instance $id exists" >&2; exit 1; }
          live=$(reservations | wc -l)
          [ "$live" -lt ${toString hostPolicy.maxConcurrentInstances} ] || refuse "instances $live of ${toString hostPolicy.maxConcurrentInstances} live"
          mem_used=$(reservations | awk '{s += $1} END {print s + 0}')
          mem_total=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
          [ $((mem_used + ${toString t.resources.memoryMiB})) -le $((mem_total - ${toString hostPolicy.reserve.memoryMiB})) ] \
            || refuse "memory $mem_used+${toString t.resources.memoryMiB} MiB over $mem_total-${toString hostPolicy.reserve.memoryMiB} MiB"
          disk_free=$(df --output=avail -BM "$state" | tail -1 | tr -dc 0-9)
          [ $((${toString diskMiB} + ${toString hostPolicy.reserve.diskMiB})) -le "$disk_free" ] \
            || refuse "disk ${toString diskMiB}+${toString hostPolicy.reserve.diskMiB} MiB over $disk_free MiB free"
          uidbase=""
          for slot in $(seq 0 63); do
            b=$((1048576 + 65536 * slot))
            if ! reservations | awk -v b="$b" '$3 == b {f = 1} END {exit !f}'; then uidbase=$b; break; fi
          done
          [ -n "$uidbase" ] || refuse "no free UID range"
          mkdir -p "$base/img" "$base/mnt"
          echo "${toString t.resources.memoryMiB} ${toString diskMiB} $uidbase ${name}" > "$base/reservation"
          created=0
          trap '[ "$created" = 1 ] || { echo "create $id failed, rolling back" >&2; teardown; }' EXIT
          vol() {  # name sizeMiB inodes mode owner-offset
            fallocate -l "$2M" "$base/img/$1.img"
            mkfs.ext4 -q -F -m 0 -N "$3" -E nodiscard,root_owner=$((uidbase + $5)):$((uidbase + $5)) "$base/img/$1.img"
            mkdir -p "$base/mnt/$1"
            mount -o loop,nosuid,nodev "$base/img/$1.img" "$base/mnt/$1"
            rmdir "$base/mnt/$1/lost+found"
            chmod "$4" "$base/mnt/$1"
          }
          ${lib.concatStrings (lib.mapAttrsToList (n: v: "vol ${n} ${toString v.sizeMiB} ${toString v.inodes} ${v.mode} ${toString v.owner}\n") volumes)}
          mkdir -p "$root"/{etc/agent-runtime,bin,usr/bin,nix/store,src,skills,proc,sys,dev}
          mkdir -p "$root"{${lib.concatStringsSep "," (map (v: v.path) (lib.attrValues volumes))}}
          ${lib.concatMapStrings (s: ''mkdir -p "$root/src/${baseNameOf s.path}"'' + "\n") (lib.attrValues m.sources)}
          ${lib.concatStrings (lib.mapAttrsToList (n: _: ''mkdir -p "$root/skills/${n}"'' + "\n") m.skills.names)}
          printf 'ID=agent-runtime\nPRETTY_NAME="agent-runtime ${name}"\n' > "$root/etc/os-release"
          printf 'root:x:0:0::/root:/bin/sh\nagent:x:1000:1000::${fs.home.path}:/bin/sh\nnobody:x:65534:65534::/:/bin/sh\n' > "$root/etc/passwd"
          printf 'root:x:0:\nagent:x:1000:\nnogroup:x:65534:\n' > "$root/etc/group"
          printf 'passwd: files\ngroup: files\n' > "$root/etc/nsswitch.conf"
          touch "$root/etc/agent-runtime/template.json"
          ln -sf ${pkgs.bash}/bin/bash "$root/bin/sh"
          ln -sf ${pkgs.coreutils}/bin/env "$root/usr/bin/env"
          created=1
          ;;
        run)  # run <id> <uid> <script> [store-bind-opt]; AGENT_RUNTIME_CRED delivers a per-run secret
          user=$1; script=$2; opt=''${3:-}; rc=0
          uidbase=$(awk '{print $3}' "$base/reservation")
          systemctl reset-failed "agent-runtime-$id.service" 2>/dev/null || true
          # a per-run credential never comes from the manifest or the store: it is written now to a private
          # tmpfs dir of this instance, owned by the mapped agent, bound read-only; redact() strips it from logs
          credbind=(); redact() { cat; }
          if [ -n "''${AGENT_RUNTIME_CRED:-}" ]; then
            cred=$AGENT_RUNTIME_CRED
            mkdir -p "$base/cred"; chmod 700 "$base/cred"
            printf '%s' "$cred" > "$base/cred/token"
            chmod 400 "$base/cred/token"; chown "$((uidbase + user))":"$((uidbase + user))" "$base/cred" "$base/cred/token"
            credbind=(--bind-ro="$base/cred:/run/agent-runtime/credentials")
            redact() { sed "s|$cred|<redacted>|g"; }
          fi
          args=(systemd-run --unit="agent-runtime-$id" --wait --pipe --collect
            -p MemoryMax=${toString t.resources.memoryMiB}M -p MemorySwapMax=0 -p TasksMax=${toString t.resources.tasksMax}
            -p CPUQuota=${toString (t.resources.cpus * 100)}% -p KillMode=mixed --setenv=SYSTEMD_LOG_TARGET=journal
            systemd-nspawn --quiet --keep-unit --settings=no --register=yes
              -M "agent-runtime-$id" -D "$root"
              --private-users="$uidbase:65536" --private-users-ownership=chown
              --private-network --as-pid2 --resolv-conf=off --timezone=off --no-new-privileges=yes
              --drop-capability=${dropCaps}
              --bind-ro="/nix/store:/nix/store$opt"
              ${sourceBinds}${skillBinds}
              --bind-ro="${manifestFile}:/etc/agent-runtime/template.json"
              "''${credbind[@]}"
              ${lib.concatStrings (lib.mapAttrsToList (n: v: ''--bind="$base/mnt/${n}:${v.path}" '') volumes)}
              /bin/sh -c "exec ${pkgs.util-linux}/bin/setpriv --reuid=$user --regid=$user --clear-groups --bounding-set=-all --inh-caps=-all --no-new-privs /bin/sh -c '$script > ${fs.tmp.path}/run.log 2>&1'")
          echo "== command ($id):"; printf '%q ' "''${args[@]}"; echo
          "''${args[@]}" || rc=$?
          echo "== run.log ($id, exit $rc):"; { cat "$base/mnt/tmp/run.log" 2>/dev/null || echo "(no run.log)"; } | redact
          if [ "$rc" != 0 ]; then echo "== nspawn journal ($id):"; journalctl --sync; journalctl -b -o cat -u "agent-runtime-$id.service" | grep -v -E "^(Started|agent-runtime-)" | tail -8 | redact; fi
          exit "$rc"
          ;;
        export)
          out=$state/exports/$id
          # the credential must not leave in an artifact: scan the output before publishing, and refuse if the
          # per-run secret appears in any file (a well-behaved agent never writes it; this is the backstop)
          if [ -n "''${AGENT_RUNTIME_CRED:-}" ] && grep -rqF "$AGENT_RUNTIME_CRED" "$base/mnt/output"; then
            echo "export refused: the run credential appears in the output of $id" >&2; exit 77
          fi
          mkdir -p "$out"
          cp -r "$base/mnt/output/." "$out"
          (cd "$out" && sha256sum -c SHA256SUMS)
          cmp "$out/template.json" ${manifestFile}
          ;;
        destroy)
          exec 9>/run/agent-runtime/.admission.lock; flock 9
          teardown
          ;;
        reservations)
          reservations | awk '{n++; m += $1; d += $2} END {printf "instances=%d memoryMiB=%d diskMiB=%d\n", n, m, d}'
          ;;
        check-clean)
          fail=0
          chk() { if "$@"; then echo "clean: $*"; else echo "LEAK: $*"; fail=1; fi; }
          chk sh -c "! findmnt -rn | grep -q 'agent-runtime/$id'"
          chk sh -c "! losetup -l -n -O BACK-FILE | grep -q '$base/'"
          chk sh -c "! systemctl list-units --all --no-legend 'agent-runtime-$id.service' | grep -q ."
          chk sh -c "! machinectl list --no-legend | grep -q 'agent-runtime-$id'"
          chk sh -c "! pgrep -a -x systemd-nspawn | grep -q 'agent-runtime-$id'"
          chk test ! -e "$base"
          chk test ! -e "/run/agent-runtime/$id"
          exit $fail
          ;;
      esac
    '';

  rust = rec {
    name = "rust-worker-m0";
    t = evaluated.templates.${name};
    m = evaluated.manifestData.${name};
    fs = m.filesystem;
    src = m.sources.rf-proto;
    env = pkgs.buildEnv { name = "agent-runtime-${name}"; paths = t.packages; };
    factory = mkFactory name;
  };
  tiny = { factory = mkFactory "tiny"; };
  inherit (rust) fs env;
  ws = fs.workspace;
  out = fs.output.path;
  probeEnv = pkgs.buildEnv { name = "agent-runtime-probe"; paths = [ env pkgs.hostname-debian ]; };
  closure = pkgs.closureInfo { rootPaths = [ env rust.src.locked.storePath rust.m.skills.source.storePath ]; };

  # Runs as container root, with no capabilities: records the boundary and tries to break it.
  probe = pkgs.writeShellScript "agent-probe" ''
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
    echo "store_owner: $(stat -c '%u:%g %A' ${env})"
    hostpid=$(cat ${ws}/host.pid)
    fail=0
    chk() { if "$@"; then echo "ok   $*"; else echo "FAIL $*"; fail=1; fi; }
    chk test ! -e /nix/var/nix/daemon-socket/socket
    chk test ! -S /run/systemd/private
    chk test ! -e /run/docker.sock
    chk test ! -e /home/host-sentinel
    chk test ! -e /root/host-sentinel
    chk test -z "''${SSH_AUTH_SOCK:-}"
    chk test "$(ls /sys/class/net)" = lo
    chk test -f /skills/rust-engineering/SKILL.md
    chk test -f /src/rf-proto/Cargo.toml
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
    deny touch /src/rf-proto/agent-runtime-write-attempt
    deny touch /skills/rust-engineering/agent-runtime-write-attempt
    deny touch ${ws}/root-write-attempt
    deny mount -o remount,rw /nix/store
    deny mount -o remount,rw /src/rf-proto
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

  # Runs as the unprivileged user `agent`: the real workload and the export.
  work = pkgs.writeShellScript "agent-work" ''
    set -euo pipefail
    export PATH=${env}/bin HOME=${fs.home.path} TMPDIR=${fs.tmp.path} CARGO_HOME=${fs.cache.path}/cargo
    echo "started_ns=$(date +%s%N)"
    echo "whoami=$(id -u):$(id -g) home=$(stat -c %u:%a $HOME) cache=$(stat -c %u:%a ${fs.cache.path}) tmp=$(stat -c %a $TMPDIR)"
    echo "status: $(grep -E '^(CapEff|CapBnd|NoNewPrivs|Seccomp):' /proc/self/status | tr -s '\t ' ' ' | tr '\n' ' ')"
    touch $HOME/.written ${fs.cache.path}/.written $TMPDIR/.written
    cp -r /src/rf-proto ${rust.src.path}
    chmod -R u+w ${rust.src.path}
    cd ${rust.src.path}
    cargo test --offline 2>&1 | tee ${out}/cargo-test.log
    test "''${PIPESTATUS[0]}" = 0
    bin=$(find target/debug/deps -maxdepth 1 -type f -perm -u+x -name 'rf_proto-*' | head -1)
    cp "$bin" ${out}/rf_proto-test
    cp /etc/agent-runtime/template.json ${out}/template.json
    (cd ${out} && sha256sum rf_proto-test template.json > SHA256SUMS)
    if touch /nix/store/agent-runtime-write-attempt 2>/dev/null; then echo "FAIL store writable"; exit 1; fi
    if touch /src/rf-proto/x 2>/dev/null; then echo "FAIL source writable"; exit 1; fi
    echo "finished_ns=$(date +%s%N)"
  '';

  # The per-run credential: read it, prove the bind is read-only, print it once (to exercise log
  # redaction), and write a clean result that must not carry it (to exercise the export gate).
  credwork = pkgs.writeShellScript "agent-cred" ''
    set -euo pipefail
    export PATH=${env}/bin
    t=/run/agent-runtime/credentials/token
    echo "cred_owner=$(stat -c %u:%a $t) whoami=$(id -u)"
    tok=$(cat $t)
    echo "using credential: $tok"
    if printf 'overwrite' > $t 2>/dev/null; then echo "FAIL credential writable"; exit 1; fi
    echo "clean result, no secret" > ${out}/result.txt
    cp /etc/agent-runtime/template.json ${out}/template.json
    (cd ${out} && sha256sum result.txt template.json > SHA256SUMS)
  '';

  # Two of these run at once: each records its identity, holds a SysV segment and its own
  # credential, waits for the host's go, then must not reach its peer's process, IPC or credential.
  conc = pkgs.writeShellScript "agent-conc" ''
    set -euo pipefail
    export PATH=${env}/bin
    me=$(cat /proc/sys/kernel/hostname)
    echo "$(id -u) $(for n in ${nsList}; do readlink /proc/self/ns/$n; done | tr '\n' ' ')" > ${ws}/identity
    echo "$me" > ${ws}/marker-$me
    cat /run/agent-runtime/credentials/token > ${ws}/my-cred
    ipcmk -M 4096 > /dev/null
    touch ${ws}/ready
    while [ ! -e ${ws}/go ]; do sleep 0.2; done
    # the peer's credential is neither at the shared path (each sees only its own bind) nor on the host
    peercred=$(cat /run/agent-runtime/credentials/token)
    test "$peercred" = "$(cat ${ws}/my-cred)" || { echo "FAIL saw another token at the shared path"; exit 1; }
    if cat "$(cat ${ws}/peer-credpath)" 2>/dev/null; then echo "FAIL read peer credential from the host"; exit 1; fi
    echo "peer credential unreadable, own token only"
    ls ${ws} | tr '\n' ' '; echo
    test "$(ls ${ws} | grep -c '^marker-')" = 1
    test "$(ipcs -m | grep -c '^0x')" = 1
    if kill -0 "$(cat ${ws}/peer.pid)" 2>/dev/null; then echo "FAIL peer signalable"; exit 1; fi
    echo "peer $(cat ${ws}/peer.pid) not signalable, own segment only"
  '';

  # Budget workloads: tasks, memory, CPU, bytes and inodes past the template's limits.
  forkbomb = pkgs.writeShellScript "agent-pids" ''
    export PATH=${env}/bin
    # xargs waits for a child and retries on EAGAIN, so the bomb sits at the limit and then ends
    seq 1 ${toString (rust.t.resources.tasksMax + 200)} | xargs -P 0 -I{} sleep 10
  '';
  hog = pkgs.writeShellScript "agent-oom" ''
    export PATH=${env}/bin
    head -c ${toString (rust.t.resources.memoryMiB * 2)}M /dev/zero | tail > /dev/null
  '';
  spin = pkgs.writeShellScript "agent-cpu" ''
    export PATH=${env}/bin
    for i in 1 2 3; do (while :; do :; done) & done
    sleep 5
    kill $(jobs -p)
  '';
  fill = pkgs.writeShellScript "agent-fill" ''
    export PATH=${env}/bin
    dd if=/dev/zero of=${ws}/fill bs=1M 2> ${fs.tmp.path}/dd.err; echo "dd_exit=$?"; head -1 ${fs.tmp.path}/dd.err
    cd ${fs.home.path}
    seq 1 ${toString (fs.home.inodes * 2)} | xargs touch 2> ${fs.tmp.path}/touch.err; echo "touch_exit=$?"; head -1 ${fs.tmp.path}/touch.err
    df -B1M --output=target,used,avail ${ws} | tail -1; df -i ${fs.home.path} | tail -1
  '';
  marker = pkgs.writeShellScript "agent-marker" ''
    echo ran > ${ws}/payload-ran
  '';
in
pkgs.testers.runNixOSTest {
  name = "agent-runtime-nspawn";

  nodes.machine = {
    virtualisation.memorySize = 4096;
    virtualisation.cores = 2;
    virtualisation.diskSize = 4096;
    # test-instrumentation's mkDefault 2 panics the VM on any cgroup OOM; hosts run the kernel's 0
    boot.kernel.sysctl."vm.panic_on_oom" = 0;
    environment.systemPackages = with pkgs; [ util-linux procps gnugrep gawk coreutils ];
  };

  testScript = ''
    import json, re, time
    NS = "${nsList}".split()
    F = "${rust.factory}"
    T = "${tiny.factory}"
    timings: dict[str, dict[str, object]] = {}

    def ms(a: int, b: int) -> int:
        return (b - a) // 1000000

    def summary(out: str, key: str) -> str:
        found = re.search(key + r": (\S+)", out)
        return found.group(1) if found else "?"

    def seconds(v: str) -> float:
        found = re.fullmatch(r"([\d.]+)(ms|s)", v)
        assert found, v
        return float(found.group(1)) / (1000 if found.group(2) == "ms" else 1)

    def reserved() -> str:
        return machine.succeed(f"{F} reservations x").strip()

    def create(i: str, f: str = F) -> int:
        t = time.monotonic_ns()
        machine.succeed(f"{f} create {i}")
        return ms(t, time.monotonic_ns())

    def teardown(i: str, f: str = F) -> int:
        t = time.monotonic_ns()
        machine.succeed(f"{f} destroy {i}")
        took = ms(t, time.monotonic_ns())
        print(machine.succeed(f"{f} check-clean {i}"))
        return took

    def disk(i: str) -> int:
        return int(machine.succeed(f"du -sbx /var/lib/agent-runtime/{i}/mnt/* /run/agent-runtime/{i} | awk '{{s+=$1}} END {{print s}}'"))

    def host_free() -> dict[str, int]:
        return {"mem_total_mib": int(machine.succeed("awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo")),
                "disk_avail_mib": int(machine.succeed("df --output=avail -BM /var/lib | tail -1 | tr -dc 0-9")),
                "mem_available_mib": int(machine.succeed("awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo"))}

    def background(i: str, script: str, f: str = F, env: str = "") -> None:
        machine.succeed(f"({env} {f} run {i} 1000 {script} {opt} > /tmp/{i}.out 2>&1; echo $? > /tmp/{i}.rc) >/dev/null 2>&1 &")

    machine.wait_for_unit("multi-user.target")
    print("=== versions ===")
    print(machine.succeed("uname -r; systemctl --version | head -1; ${pkgs.systemd}/bin/systemd-nspawn --version | head -1"))
    print("nixpkgs ${pkgs.lib.version}; rf-proto ${rfProto.rev}; skills ${skills.rev or "unpinned"}")
    print("template digest ${rust.m.digests.template}; host policy reserve memoryMiB=${toString hostPolicy.reserve.memoryMiB} diskMiB=${toString hostPolicy.reserve.diskMiB} max ${toString hostPolicy.maxConcurrentInstances}")
    closure = {"paths": int(machine.succeed("wc -l < ${closure}/store-paths")), "nar_bytes": int(machine.succeed("cat ${closure}/total-nar-size"))}
    print("closure:", closure)
    print("=== host: namespaces, maps, mountinfo ===")
    host_ns = {n: machine.succeed(f"readlink /proc/1/ns/{n}").strip() for n in NS}
    print(host_ns)
    print(machine.succeed("cat /proc/1/uid_map /proc/1/gid_map; cat /proc/1/mountinfo"))
    machine.succeed("touch /root/host-sentinel /home/host-sentinel")
    store_before = machine.succeed("ls /nix/store | wc -l; stat -c %Y /nix/store").split()
    host_before = host_free()
    print("host before:", host_before)
    host_pid = machine.succeed("systemd-run --unit=host-sleeper --property=Type=exec sleep 3600 >/dev/null; systemctl show -p MainPID --value host-sleeper").strip()
    shm = machine.succeed("ipcmk -M 4096 | grep -o '[0-9]*$'").strip()

    with subtest("bad instance ids are refused"):
        for bad in ("exports", "../x", "A", "-x"):
            machine.fail(f"{F} create '{bad}'")

    with subtest("idle instance: create cost, runtime start, memory overhead"):
        c = create("idle")
        print(machine.succeed("findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS | grep agent-runtime/idle; losetup -l -n"))
        t0 = time.monotonic_ns()
        status, out = machine.execute(f"{F} run idle 0 ${pkgs.coreutils}/bin/true :idmap 2>&1")
        opt = ":idmap" if status == 0 else ""
        if not opt:
            print("=== :idmap refused, plain read-only bind; reservation kept across the failed start:", reserved())
            assert reserved().startswith("instances=1 ")
            status, out = machine.execute(f"{F} run idle 0 ${pkgs.coreutils}/bin/true 2>&1")
        assert status == 0, out
        t1 = time.monotonic_ns()
        print(out[-800:])
        timings["idle"] = {"create_ms": c, "run_ms": ms(t0, t1), "memory_peak": summary(out, "Memory peak"), "disk_bytes": disk("idle")}
        timings["idle"]["teardown_ms"] = teardown("idle")
        assert reserved() == "instances=0 memoryMiB=0 diskMiB=0", reserved()

    with subtest("probe as container root: no capabilities, namespaces, read-only store and sources"):
        create("probe")
        machine.succeed(f"echo {host_pid} > /var/lib/agent-runtime/probe/mnt/workspace/host.pid")
        out = machine.succeed(f"{F} run probe 0 ${probe} {opt}")
        print(out)
        assert "FAIL" not in out
        guest_ns = dict(re.findall(r"^ns_(\w+): (\S+)$", out, re.M))
        shared = [n for n in NS if guest_ns[n] == host_ns[n]]
        print("namespaces shared with the host:", shared)
        assert shared == ["time"], shared
        assert machine.succeed("hostname").strip() == "machine", "guest changed the host hostname"
        machine.succeed(f"ipcs -m -i {shm}")
        machine.succeed(f"kill -0 {host_pid}")
        teardown("probe")

    for run in ("cold", "warm"):
        with subtest(f"{run}: create -> cargo test as agent -> export -> destroy"):
            t0 = time.monotonic_ns()
            wall0 = int(machine.succeed("date +%s%N"))
            c = create(run)
            status, out = machine.execute(f"{F} run {run} 1000 ${work} {opt} 2>&1")
            t1 = time.monotonic_ns()
            runlog = out[out.index("== run.log"):]
            print(out[:out.index("== run.log")][-400:]); print(runlog[:1200]); print("..."); print(runlog[-1200:])
            assert status == 0, "workload failed"
            assert re.search(r"test result: ok\. \d+ passed", out), "cargo test did not report a pass"
            assert re.search(r"^status: CapEff: 0+ CapBnd: 0+ NoNewPrivs: 1 Seccomp: 2 $", out, re.M), "agent kept privileges"
            marks = re.search(r"started_ns=(\d+).*finished_ns=(\d+)", out, re.S)
            assert marks, "the workload did not print both time marks"
            started, finished = int(marks.group(1)), int(marks.group(2))
            timings[run] = {"create_ms": c, "startup_ms": (started - wall0) // 1000000, "work_ms": (finished - started) // 1000000,
                            "total_ms": ms(t0, t1), "memory_peak": summary(out, "Memory peak"), "cpu": summary(out, "CPU time consumed"),
                            "disk_bytes": disk(run)}
            print(machine.succeed(f"{F} export {run}"))
            timings[run]["teardown_ms"] = teardown(run)
            timings[run]["export_bytes"] = int(machine.succeed(f"du -sb /var/lib/agent-runtime/exports/{run} | cut -f1"))

    with subtest("per-run credential: delivered read-only, redacted from the log, kept out of the export"):
        create("cred")
        secret = "glpat-REDACTME-" + "0123456789abcdef"
        status, out = machine.execute(f"AGENT_RUNTIME_CRED={secret} {F} run cred 1000 ${credwork} {opt} 2>&1")
        print(out)
        assert status == 0, "credential workload failed"
        assert secret not in out, "the credential leaked into the run log"
        assert "using credential: <redacted>" in out, "the credential was not redacted in the log"
        assert "cred_owner=1000:400" in out, out
        assert "FAIL credential writable" not in out
        # the credential is nowhere in the store or the manifest
        machine.succeed(f"! grep -rqF {secret} /nix/store/*agent-runtime* 2>/dev/null")
        print(machine.succeed(f"AGENT_RUNTIME_CRED={secret} {F} export cred"))
        machine.succeed(f"! grep -rqF {secret} /var/lib/agent-runtime/exports/cred")
        # the export gate refuses an output that carries the secret
        machine.succeed(f"printf '%s' {secret} > /var/lib/agent-runtime/cred/mnt/output/leak.txt")
        status, out = machine.execute(f"AGENT_RUNTIME_CRED={secret} {F} export cred 2>&1")
        assert status == 77 and "export refused" in out, ("the export gate did not catch the leak", status, out)
        machine.succeed("rm /var/lib/agent-runtime/cred/mnt/output/leak.txt")
        teardown("cred")

    with subtest("two concurrent instances: distinct identities, namespaces, workspaces, IPC, process trees and credentials"):
        for i in ("conc-a", "conc-b"):
            create(i)
            machine.succeed(f"echo /var/lib/agent-runtime/{'conc-b' if i == 'conc-a' else 'conc-a'}/cred/token > /var/lib/agent-runtime/{i}/mnt/workspace/peer-credpath")
            background(i, "${conc}", env=f"AGENT_RUNTIME_CRED=token-of-{i}")
        machine.wait_until_succeeds("test -e /var/lib/agent-runtime/conc-a/mnt/workspace/ready && test -e /var/lib/agent-runtime/conc-b/mnt/workspace/ready", timeout=60)
        print(machine.succeed("machinectl list --no-legend"))
        assert machine.succeed("machinectl list --no-legend | grep -c agent-runtime-conc-").strip() == "2"
        print("reserved with two live:", reserved())
        ids = {}
        for i in ("conc-a", "conc-b"):
            w = f"/var/lib/agent-runtime/{i}/mnt/workspace"
            ids[i] = {"host_uid": machine.succeed(f"stat -c %u {w}/identity").strip(), "guest": machine.succeed(f"cat {w}/identity").split(),
                      "leader": machine.succeed(f"machinectl show -p Leader --value agent-runtime-{i}").strip()}
        print(ids)
        assert ids["conc-a"]["host_uid"] != ids["conc-b"]["host_uid"]
        for k, n in enumerate(["uid"] + NS):
            same = ids["conc-a"]["guest"][k] == ids["conc-b"]["guest"][k]
            assert same == (n in ("uid", "time")), (n, ids)
        for i, peer in (("conc-a", "conc-b"), ("conc-b", "conc-a")):
            machine.succeed(f"echo {ids[peer]['leader']} > /var/lib/agent-runtime/{i}/mnt/workspace/peer.pid")
        print("host sees two guest SysV segments:", machine.succeed("ipcs -m | grep -c '^0x' || true").strip(), "(its own only)")
        for i in ("conc-a", "conc-b"):
            machine.succeed(f"touch /var/lib/agent-runtime/{i}/mnt/workspace/go")
        for i in ("conc-a", "conc-b"):
            machine.wait_until_succeeds(f"test -e /tmp/{i}.rc", timeout=60)
            print(machine.succeed(f"cat /tmp/{i}.out"))
            assert machine.succeed(f"cat /tmp/{i}.rc").strip() == "0"
            teardown(i)

    with subtest("admission: memory, instance count and disk refuse oversubscription"):
        create("adm-a"); create("adm-b")
        print("two rust instances:", reserved())
        status, out = machine.execute(f"{F} create adm-c 2>&1")
        print(out); assert status == 75 and "admission refused: memory" in out, out
        machine.succeed("test ! -e /var/lib/agent-runtime/adm-c")
        create("adm-t1", T)
        status, out = machine.execute(f"{T} create adm-t2 2>&1")
        print(out); assert status == 75 and "admission refused: instances 3 of 3" in out, out
        for i in ("adm-a", "adm-b"):
            teardown(i)
        teardown("adm-t1", T)
        free = int(machine.succeed("df --output=avail -BM /var/lib/agent-runtime | tail -1 | tr -dc 0-9"))
        ballast = free - ${toString hostPolicy.reserve.diskMiB} - 100
        machine.succeed(f"fallocate -l {ballast}M /var/lib/ballast")
        status, out = machine.execute(f"{F} create adm-d 2>&1")
        print(out); assert status == 75 and "admission refused: disk" in out, out
        create("adm-t3", T)
        teardown("adm-t3", T)
        machine.succeed("rm /var/lib/ballast")
        assert reserved() == "instances=0 memoryMiB=0 diskMiB=0", reserved()

    with subtest("fail closed: no user namespace, no payload; reservation held until destroy"):
        create("nouserns", T)
        userns_max = machine.succeed("cat /proc/sys/user/max_user_namespaces").strip()
        machine.succeed("sysctl -w user.max_user_namespaces=0")
        status, out = machine.execute(f"{T} run nouserns 1000 ${marker} 2>&1")
        machine.succeed(f"sysctl -w user.max_user_namespaces={userns_max}")
        print(out[-600:])
        assert status != 0, "instance started without a user namespace"
        machine.succeed("test ! -e /var/lib/agent-runtime/nouserns/mnt/workspace/payload-ran")
        assert reserved().startswith("instances=1 "), reserved()
        teardown("nouserns", T)

    with subtest("failed teardown keeps the reservation; a second destroy releases it"):
        create("busy", T)
        machine.succeed("systemd-run --unit=holder --property=Type=exec --working-directory=/var/lib/agent-runtime/busy/mnt/workspace sleep 600")
        machine.fail(f"{T} destroy busy")
        held = reserved()
        print("after failed destroy:", held)
        assert held.startswith("instances=1 "), held
        machine.succeed("systemctl stop holder")
        teardown("busy", T)
        assert reserved() == "instances=0 memoryMiB=0 diskMiB=0", reserved()

    with subtest("budget: tasksMax holds a fork bomb"):
        create("pids")
        background("pids", "${forkbomb}")
        cg = "/sys/fs/cgroup/system.slice/agent-runtime-pids.service"
        machine.wait_until_succeeds(f"awk '$1 == \"max\" && $2 > 0' {cg}/pids.events | grep -q .", timeout=120)
        tasks = int(machine.succeed(f"cat {cg}/pids.current"))
        events = machine.succeed(f"cat {cg}/pids.events").strip()
        print("pids.current", tasks, "pids.max", machine.succeed(f"cat {cg}/pids.max").strip(), events)
        assert tasks <= ${toString rust.t.resources.tasksMax}, tasks
        machine.wait_until_succeeds("test -e /tmp/pids.rc", timeout=120)
        timings["pids"] = {"pids_current": tasks, "pids_events": events, "rc": machine.succeed("cat /tmp/pids.rc").strip(), "teardown_ms": teardown("pids")}
        machine.succeed("systemctl is-system-running --wait | grep -E 'running|degraded'")

    with subtest("budget: memoryMiB ends a memory hog with an OOM kill"):
        create("oom")
        status, out = machine.execute(f"{F} run oom 1000 ${hog} {opt} 2>&1")
        print(out[-1200:])
        assert status != 0, "the hog was not stopped"
        assert "Finished with result: oom-kill" in out, "no oom-kill result"
        timings["oom"] = {"memory_peak": summary(out, "Memory peak"), "teardown_ms": teardown("oom")}
        print(machine.succeed("dmesg | grep -iE 'memory cgroup out of memory|oom-kill' | tail -3"))

    with subtest("budget: cpus caps three busy loops at one core"):
        create("cpu")
        status, out = machine.execute(f"{F} run cpu 1000 ${spin} {opt} 2>&1")
        print(out[-600:])
        runtime_s, cpu_s = seconds(summary(out, "Service runtime")), seconds(summary(out, "CPU time consumed"))
        print("runtime", runtime_s, "cpu", cpu_s)
        assert cpu_s <= runtime_s * ${toString rust.t.resources.cpus} * 1.15, (runtime_s, cpu_s)
        timings["cpu"] = {"runtime_s": runtime_s, "cpu_s": cpu_s, "teardown_ms": teardown("cpu")}

    with subtest("budget: bytes and inodes run out inside the instance, not on the host"):
        create("fill")
        after_create = host_free()
        status, out = machine.execute(f"{F} run fill 1000 ${fill} {opt} 2>&1")
        print(out[-900:])
        assert re.search(r"dd_exit=1\n.*No space left on device", out), "the workspace did not fill"
        assert re.search(r"touch_exit=[1-9]\d*\n.*No space left on device", out), "inodes did not run out"
        during = host_free()
        print("host after create", after_create, "after fill", during)
        assert during["disk_avail_mib"] >= after_create["disk_avail_mib"] - 2, (after_create, during)
        timings["fill"] = {"host_disk_delta_mib": during["disk_avail_mib"] - after_create["disk_avail_mib"], "teardown_ms": teardown("fill")}

    with subtest("host unchanged, nothing left behind"):
        store_after = machine.succeed("ls /nix/store | wc -l; stat -c %Y /nix/store").split()
        assert store_before == store_after, (store_before, store_after)
        machine.succeed("test -f /root/host-sentinel -a -f /home/host-sentinel")
        machine.succeed("test ! -e /nix/store/agent-runtime-write-attempt")
        machine.succeed("! findmnt -rn | grep agent-runtime")
        machine.succeed("! losetup -l -n | grep -q agent-runtime")
        machine.succeed("! machinectl list --no-legend | grep -q .")
        machine.succeed("! systemctl list-units --all --no-legend 'agent-runtime-*' | grep -q .")
        machine.succeed("test -z \"$(ls /var/lib/agent-runtime | grep -v '^exports$')\"")
        host_after = host_free()
        print("host before", host_before, "after", host_after)
        assert abs(host_after["disk_avail_mib"] - host_before["disk_avail_mib"]) <= 16, (host_before, host_after)
        print("exports kept:", machine.succeed("ls /var/lib/agent-runtime/exports").split())

    print("=== measurements ===")
    print(json.dumps({"store_bind": opt, "closure": closure, "shared_namespaces": shared, "host_before": host_before,
                      "host_after": host_after, "timings": timings}, indent=2))
  '';
}
