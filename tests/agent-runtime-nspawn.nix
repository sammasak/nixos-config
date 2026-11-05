# M0 proof for the ephemeral nspawn agent runtime (#135): one template declared
# through the typed module (#134; one pinned GitHub Rust repo, one named skill,
# Nix packages, budgets) materialised as user-namespaced systemd-nspawn instances
# by a transient-unit factory, never by a host switch or a static
# containers.<name> entry. Runs only in QEMU:
# nix build .#packages.x86_64-linux.agent-runtime-nspawn
{ pkgs, lib, rfProto, skills }:
let
  runtime = import ../modules/agent-runtime/lib.nix { inherit lib pkgs; };
  name = "rust-worker-m0";
  evaluated = runtime.evalManifests {
    modules = [
      {
        sam.agentRuntime.host = {
          enable = true;
          eligibleTemplates = [ name ];
          maxConcurrentInstances = 2;
        };
        sam.agentRuntime.templates.${name} = {
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
            home.sizeMiB = 256;
            tmp.sizeMiB = 256;
            cache.sizeMiB = 512;
            output.sizeMiB = 64;
          };
          resources = { cpus = 2; memoryMiB = 1024; tasksMax = 512; timeoutMinutes = 30; };
        };
      }
    ];
  };
  t = evaluated.templates.${name};
  m = evaluated.manifestData.${name};
  manifestFile = "${evaluated.manifestDir}/${name}.json";
  fs = m.filesystem;
  src = m.sources.rf-proto;
  skill = { store = m.skills.names.rust-engineering.path; path = "/skills/rust-engineering"; };
  env = pkgs.buildEnv { name = "agent-runtime-${name}"; paths = t.packages; };
  # the probe's extra tools stay out of the template's environment
  probeEnv = pkgs.buildEnv { name = "agent-runtime-probe"; paths = [ env pkgs.hostname-debian ]; };
  closure = pkgs.closureInfo { rootPaths = [ env src.locked.storePath m.skills.source.storePath ]; };
  tmpfs = mode: b: "${b.path}:${mode},size=${toString b.sizeMiB}M,nr_inodes=${toString b.inodes}";
  agentOwned = "mode=0700,uid=1000,gid=1000";
  nsList = "user mnt pid ipc uts net cgroup time";

  # Runs as root inside the instance: records the boundary and tries to break it.
  probe = pkgs.writeShellScript "agent-probe" ''
    set -u
    export PATH=${probeEnv}/bin
    for n in ${nsList}; do echo "ns_$n: $(readlink /proc/self/ns/$n)"; done
    echo "uid_map: $(tr -s ' ' < /proc/self/uid_map)"
    echo "gid_map: $(tr -s ' ' < /proc/self/gid_map)"
    echo "cgroup: $(cat /proc/self/cgroup)"
    echo "caps: $(grep -E '^Cap(Eff|Bnd)' /proc/self/status | tr -s '\t ' ' ' | tr '\n' ' ')"
    echo "mountinfo:"; sed 's/^/  /' /proc/self/mountinfo
    echo "dev: $(ls /dev | tr '\n' ' ')"
    echo "net: $(ls /sys/class/net | tr '\n' ' ')"
    echo "pids_visible: $(ls /proc | grep -cE '^[0-9]+$')"
    echo "store_owner: $(stat -c '%u:%g %A' ${env})"
    hostpid=$(cat ${fs.workspace}/host.pid)
    fail=0
    chk() { if "$@"; then echo "ok   $*"; else echo "FAIL $*"; fail=1; fi; }
    chk test ! -e /nix/var/nix/daemon-socket/socket
    chk test ! -S /run/systemd/private
    chk test ! -e /run/docker.sock
    chk test ! -e /home/host-sentinel
    chk test ! -e /root/host-sentinel
    chk test -z "''${SSH_AUTH_SOCK:-}"
    chk test "$(ls /sys/class/net)" = lo
    chk test -f ${skill.path}/SKILL.md
    chk test -f /src/rf-proto/Cargo.toml
    chk test "$(awk '{print $2}' /proc/self/uid_map)" != 0
    chk test "$(awk '{print $2}' /proc/self/gid_map)" != 0
    chk grep -q 'NoNewPrivs:.1' /proc/self/status
    chk sh -c '! ipcs -m | grep -q "^0x"'
    deny() { if "$@" 2>/dev/null; then echo "FAIL (succeeded) $*"; fail=1; else echo "denied $*"; fi; }
    deny kill -0 "$hostpid"
    deny touch /nix/store/agent-runtime-write-attempt
    deny touch ${env}/bin/agent-runtime-write-attempt
    deny touch /src/rf-proto/agent-runtime-write-attempt
    deny touch ${skill.path}/agent-runtime-write-attempt
    deny mount -o remount,rw /nix/store
    deny mount -o remount,rw /src/rf-proto
    deny mount -o remount,rw /
    deny mknod /dev/sda b 8 0
    deny sh -c 'echo 1 > /proc/sys/kernel/sysrq'
    echo "hostname_set: $(hostname agent-probe-renamed 2>&1; echo "exit=$?") now=$(hostname)"
    chk sh -c 'echo probe > ${fs.workspace}/probe.txt'
    chk sh -c 'echo probe > ${fs.tmp.path}/probe.txt'
    exit $fail
  '';

  # Runs as the unprivileged user `agent`: the real workload and the export.
  work = pkgs.writeShellScript "agent-work" ''
    set -euo pipefail
    export PATH=${env}/bin HOME=${fs.home.path} TMPDIR=${fs.tmp.path} CARGO_HOME=${fs.cache.path}/cargo
    echo "started_ns=$(date +%s%N)"
    echo "whoami=$(id -u):$(id -g) home=$(stat -c %u:%a $HOME) cache=$(stat -c %u:%a ${fs.cache.path}) tmp=$(stat -c %a $TMPDIR)"
    touch $HOME/.written ${fs.cache.path}/.written $TMPDIR/.written
    cp -r /src/rf-proto ${src.path}
    chmod -R u+w ${src.path}
    cd ${src.path}
    cargo test --offline 2>&1 | tee ${fs.output.path}/cargo-test.log
    test "''${PIPESTATUS[0]}" = 0
    bin=$(find target/debug/deps -maxdepth 1 -type f -perm -u+x -name 'rf_proto-*' | head -1)
    cp "$bin" ${fs.output.path}/rf_proto-test
    cp /etc/agent-runtime/template.json ${fs.output.path}/template.json
    (cd ${fs.output.path} && sha256sum rf_proto-test template.json > SHA256SUMS)
    if touch /nix/store/agent-runtime-write-attempt 2>/dev/null; then echo "FAIL store writable"; exit 1; fi
    if touch /src/rf-proto/x 2>/dev/null; then echo "FAIL source writable"; exit 1; fi
    echo "finished_ns=$(date +%s%N)"
  '';

  # Two of these run at once: each records its identity, waits for the host's
  # go, then must see only its own marker in its workspace.
  conc = pkgs.writeShellScript "agent-conc" ''
    set -euo pipefail
    export PATH=${env}/bin
    me=$(cat /proc/sys/kernel/hostname)
    echo "$(id -u) $(for n in ${nsList}; do readlink /proc/self/ns/$n; done | tr '\n' ' ')" > ${fs.workspace}/identity
    echo "$me" > ${fs.workspace}/marker-$me
    touch ${fs.workspace}/ready
    while [ ! -e ${fs.workspace}/go ]; do sleep 0.2; done
    ls ${fs.workspace} | tr '\n' ' '
    test "$(ls ${fs.workspace} | grep -c '^marker-')" = 1
  '';

  # Budget workloads: more tasks than tasksMax, more memory than memoryMiB.
  forkbomb = pkgs.writeShellScript "agent-pids" ''
    export PATH=${env}/bin
    # xargs waits for a child and retries on EAGAIN, so the bomb sits at the limit and then ends
    seq 1 ${toString (t.resources.tasksMax + 200)} | xargs -P 0 -I{} sleep 10
  '';
  hog = pkgs.writeShellScript "agent-oom" ''
    export PATH=${env}/bin
    head -c ${toString (t.resources.memoryMiB * 2)}M /dev/zero | tail > /dev/null
  '';

  # The factory: one ephemeral instance per call, a transient service unit, a
  # UID range of its own per live instance, everything it touches under its id.
  factory = pkgs.writeShellScript "agent-runtime" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath (with pkgs; [ bash coreutils diffutils gnugrep findutils util-linux procps systemd ])}
    cmd=$1; id=$2; shift 2
    base=/var/lib/agent-runtime/$id
    root=/run/agent-runtime/$id/root
    case $cmd in
      create)
        mkdir -p /var/lib/agent-runtime /run/agent-runtime
        exec 9>/run/agent-runtime/.uid.lock; flock 9
        [ ! -e "$base" ] || { echo "instance $id exists" >&2; exit 1; }
        uidbase=""
        for slot in $(seq 0 63); do
          b=$((1048576 + 65536 * slot))
          if ! cat /var/lib/agent-runtime/*/uidbase 2>/dev/null | grep -qx "$b"; then uidbase=$b; break; fi
        done
        [ -n "$uidbase" ] || { echo "no free UID range" >&2; exit 1; }
        mkdir -p "$base/workspace" "$base/output" "$root"/{etc,bin,usr/bin,nix/store,src/rf-proto,${lib.removePrefix "/" skill.path},etc/agent-runtime,proc,sys,dev}
        mkdir -p "$root"{${fs.workspace},${fs.home.path},${fs.tmp.path},${fs.cache.path},${fs.output.path}}
        printf 'ID=agent-runtime\nPRETTY_NAME="agent-runtime ${name}"\n' > "$root/etc/os-release"
        printf 'root:x:0:0::/root:/bin/sh\nagent:x:1000:1000::${fs.home.path}:/bin/sh\nnobody:x:65534:65534::/:/bin/sh\n' > "$root/etc/passwd"
        printf 'root:x:0:\nagent:x:1000:\nnogroup:x:65534:\n' > "$root/etc/group"
        printf 'passwd: files\ngroup: files\n' > "$root/etc/nsswitch.conf"
        touch "$root/etc/agent-runtime/template.json"
        ln -sf ${pkgs.bash}/bin/bash "$root/bin/sh"
        ln -sf ${pkgs.coreutils}/bin/env "$root/usr/bin/env"
        ln -sf ${pkgs.glibc.bin}/bin/getent "$root/usr/bin/getent"
        chown -R $((uidbase + 1000)):$((uidbase + 1000)) "$base/workspace" "$base/output"
        echo "$uidbase" > "$base/uidbase"
        ;;
      run)  # run <id> <uid> <script> [store-bind-opt]: the switch to <uid> happens inside, with setpriv
        user=$1; script=$2; opt=''${3:-}; rc=0
        uidbase=$(cat "$base/uidbase")
        systemctl reset-failed "agent-runtime-$id.service" 2>/dev/null || true
        args=(systemd-run --unit="agent-runtime-$id" --wait --pipe --collect
          -p MemoryMax=${toString t.resources.memoryMiB}M -p MemorySwapMax=0 -p TasksMax=${toString t.resources.tasksMax}
          -p CPUQuota=${toString (t.resources.cpus * 100)}% -p KillMode=mixed
          systemd-nspawn --quiet --keep-unit --settings=no --register=yes
            -M "agent-runtime-$id" -D "$root"
            --private-users="$uidbase:65536" --private-users-ownership=chown
            --private-network --as-pid2 --resolv-conf=off --timezone=off --no-new-privileges=yes
            --bind-ro="/nix/store:/nix/store$opt"
            --bind-ro="${src.locked.storePath}:/src/rf-proto$opt"
            --bind-ro="${skill.store}:${skill.path}$opt"
            --bind-ro="${manifestFile}:/etc/agent-runtime/template.json"
            --bind="$base/workspace:${fs.workspace}"
            --bind="$base/output:${fs.output.path}"
            --tmpfs="${tmpfs "mode=1777" fs.tmp}"
            --tmpfs="${tmpfs agentOwned fs.home}"
            --tmpfs="${tmpfs agentOwned fs.cache}"
            /bin/sh -c "${pkgs.coreutils}/bin/chown 1000:1000 ${fs.home.path} ${fs.cache.path} && exec ${pkgs.util-linux}/bin/setpriv --reuid=$user --regid=$user --clear-groups --no-new-privs /bin/sh -c '$script > ${fs.workspace}/run.log 2>&1'")
        echo "== command ($id):"; printf '%q ' "''${args[@]}"; echo
        "''${args[@]}" || rc=$?
        echo "== run.log ($id, exit $rc):"; cat "$base/workspace/run.log" 2>/dev/null || echo "(no run.log)"
        exit "$rc"
        ;;
      export)
        out=/var/lib/agent-runtime/exports/$id
        mkdir -p "$out"
        cp -r "$base/output/." "$out"
        (cd "$out" && sha256sum -c SHA256SUMS)
        cmp "$out/template.json" ${manifestFile}
        ;;
      destroy)
        systemctl stop "agent-runtime-$id.service" 2>/dev/null || true
        systemctl reset-failed "agent-runtime-$id.service" 2>/dev/null || true
        if mountpoint -q "$root"; then umount -R "$root"; fi
        rm -rf "$base" "/run/agent-runtime/$id"
        ;;
      check-clean)
        fail=0
        chk() { if "$@"; then echo "clean: $*"; else echo "LEAK: $*"; fail=1; fi; }
        chk sh -c "! findmnt -rn | grep -q 'agent-runtime/$id'"
        chk sh -c "! systemctl list-units --all --no-legend 'agent-runtime-$id.service' | grep -q ."
        chk sh -c "! machinectl list --no-legend | grep -q 'agent-runtime-$id'"
        chk sh -c "! pgrep -a -x systemd-nspawn | grep -q 'agent-runtime-$id'"
        chk test ! -e "$base"
        chk test ! -e "/run/agent-runtime/$id"
        exit $fail
        ;;
    esac
  '';
in
pkgs.testers.runNixOSTest {
  name = "agent-runtime-nspawn";

  nodes.machine = {
    virtualisation.memorySize = 3072;
    virtualisation.cores = 2;
    virtualisation.diskSize = 2048;
    # test-instrumentation's mkDefault 2 panics the VM on any cgroup OOM; hosts run the kernel's 0
    boot.kernel.sysctl."vm.panic_on_oom" = 0;
    environment.systemPackages = with pkgs; [ util-linux procps gnugrep gawk coreutils ];
  };

  testScript = ''
    import json, re, time
    NS = "${nsList}".split()
    F = "${factory}"
    timings: dict[str, dict[str, object]] = {}

    def ms(a: int, b: int) -> int:
        return (b - a) // 1000000

    def peak(out: str) -> str:
        found = re.search(r"Memory peak: (\S+)", out)
        return found.group(1) if found else "?"

    def cpu(out: str) -> str:
        found = re.search(r"CPU time consumed: (\S+)", out)
        return found.group(1) if found else "?"

    def teardown(i: str) -> int:
        t = time.monotonic_ns()
        machine.succeed(f"{F} destroy {i}")
        took = ms(t, time.monotonic_ns())
        print(machine.succeed(f"{F} check-clean {i}"))
        return took

    def disk(i: str) -> int:
        return int(machine.succeed(f"du -sbx /var/lib/agent-runtime/{i} /run/agent-runtime/{i} | awk '{{s+=$1}} END {{print s}}'"))

    machine.wait_for_unit("multi-user.target")
    print("=== versions ===")
    print(machine.succeed("uname -r; systemctl --version | head -1; ${pkgs.systemd}/bin/systemd-nspawn --version | head -1"))
    print("nixpkgs ${pkgs.lib.version}; rf-proto ${rfProto.rev}; skills ${skills.rev or "unpinned"}")
    print("template digest ${m.digests.template}; manifest ${manifestFile}")
    closure = {"paths": int(machine.succeed("wc -l < ${closure}/store-paths")), "nar_bytes": int(machine.succeed("cat ${closure}/total-nar-size"))}
    print("closure:", closure)
    print("=== host: namespaces, maps, mountinfo ===")
    host_ns = {n: machine.succeed(f"readlink /proc/1/ns/{n}").strip() for n in NS}
    print(host_ns)
    print(machine.succeed("cat /proc/1/uid_map /proc/1/gid_map; cat /proc/1/mountinfo"))
    machine.succeed("touch /root/host-sentinel /home/host-sentinel")
    store_before = machine.succeed("ls /nix/store | wc -l; stat -c %Y /nix/store").split()
    host_pid = machine.succeed("systemd-run --unit=host-sleeper --property=Type=exec sleep 3600 >/dev/null; systemctl show -p MainPID --value host-sleeper").strip()
    shm = machine.succeed("ipcmk -M 4096 | grep -o '[0-9]*$'").strip()

    with subtest("idle instance: runtime start and memory overhead"):
        t0 = time.monotonic_ns()
        machine.succeed(f"{F} create idle")
        status, out = machine.execute(f"{F} run idle 0 ${pkgs.coreutils}/bin/true :idmap 2>&1")
        opt = ":idmap" if status == 0 else ""
        if not opt:
            print("=== :idmap refused:", machine.execute("journalctl -b -o cat -u agent-runtime-idle.service | grep -m3 -iE 'idmap|clone|failed'")[1])
            status, out = machine.execute(f"{F} run idle 0 ${pkgs.coreutils}/bin/true 2>&1")
        assert status == 0, out
        t1 = time.monotonic_ns()
        print("=== store bind option:", repr(opt)); print(out[-800:])
        timings["idle"] = {"start_run_stop_ms": ms(t0, t1), "memory_peak": peak(out), "disk_bytes": disk("idle")}
        timings["idle"]["teardown_ms"] = teardown("idle")

    with subtest("probe as container root: boundary, namespaces, read-only store and sources"):
        machine.succeed(f"{F} create probe")
        machine.succeed(f"echo {host_pid} > /var/lib/agent-runtime/probe/workspace/host.pid")
        out = machine.succeed(f"{F} run probe 0 ${probe} {opt}")
        print(out)
        assert "FAIL" not in out
        guest_ns = dict(re.findall(r"^ns_(\w+): (\S+)$", out, re.M))
        shared = [n for n in NS if guest_ns[n] == host_ns[n]]
        print("namespaces shared with the host:", shared)
        assert not {"user", "mnt", "pid", "ipc", "uts", "net"} & set(shared), shared
        assert machine.succeed("hostname").strip() == "machine", "guest changed the host hostname"
        machine.succeed(f"ipcs -m -i {shm}")
        machine.succeed(f"kill -0 {host_pid}")
        teardown("probe")

    for run in ("cold", "warm"):
        with subtest(f"{run}: create -> cargo test as agent -> export -> destroy"):
            t0 = time.monotonic_ns()
            wall0 = int(machine.succeed("date +%s%N"))
            machine.succeed(f"{F} create {run}")
            status, out = machine.execute(f"{F} run {run} 1000 ${work} {opt} 2>&1")
            t1 = time.monotonic_ns()
            runlog = out[out.index("== run.log"):]
            print(out[:out.index("== run.log")][-400:]); print(runlog[:1200]); print("..."); print(runlog[-1200:])
            assert status == 0, "workload failed"
            assert re.search(r"test result: ok\. \d+ passed", out), "cargo test did not report a pass"
            marks = re.search(r"started_ns=(\d+).*finished_ns=(\d+)", out, re.S)
            assert marks, "the workload did not print both time marks"
            started, finished = int(marks.group(1)), int(marks.group(2))
            timings[run] = {"startup_ms": (started - wall0) // 1000000, "work_ms": (finished - started) // 1000000,
                            "total_ms": ms(t0, t1), "memory_peak": peak(out), "cpu": cpu(out),
                            "disk_bytes": disk(run)}
            print(machine.succeed(f"{F} export {run}"))
            timings[run]["teardown_ms"] = teardown(run)
            timings[run]["export_bytes"] = int(machine.succeed(f"du -sb /var/lib/agent-runtime/exports/{run} | cut -f1"))

    with subtest("two concurrent instances: distinct identities, namespaces and workspaces"):
        for i in ("conc-a", "conc-b"):
            machine.succeed(f"{F} create {i}")
            machine.succeed(f"({F} run {i} 1000 ${conc} {opt} > /tmp/{i}.out 2>&1; echo $? > /tmp/{i}.rc) >/dev/null 2>&1 &")
        machine.wait_until_succeeds("test -e /var/lib/agent-runtime/conc-a/workspace/ready && test -e /var/lib/agent-runtime/conc-b/workspace/ready", timeout=60)
        print(machine.succeed("machinectl list --no-legend"))
        assert machine.succeed("machinectl list --no-legend | grep -c agent-runtime-conc-").strip() == "2"
        ids = {}
        for i in ("conc-a", "conc-b"):
            w = f"/var/lib/agent-runtime/{i}/workspace"
            ids[i] = {"host_uid": machine.succeed(f"stat -c %u {w}/identity").strip(), "guest": machine.succeed(f"cat {w}/identity").split()}
        print(ids)
        assert ids["conc-a"]["host_uid"] != ids["conc-b"]["host_uid"]
        for k, n in enumerate(["uid"] + NS):
            same = ids["conc-a"]["guest"][k] == ids["conc-b"]["guest"][k]
            assert same == (n in ("uid", "time")), (n, ids)
        for i in ("conc-a", "conc-b"):
            machine.succeed(f"touch /var/lib/agent-runtime/{i}/workspace/go")
        for i in ("conc-a", "conc-b"):
            machine.wait_until_succeeds(f"test -e /tmp/{i}.rc", timeout=60)
            print(machine.succeed(f"cat /tmp/{i}.out"))
            assert machine.succeed(f"cat /tmp/{i}.rc").strip() == "0"
            teardown(i)

    with subtest("budget: tasksMax holds a fork bomb"):
        machine.succeed(f"{F} create pids")
        machine.succeed(f"({F} run pids 1000 ${forkbomb} {opt} > /tmp/pids.out 2>&1; echo $? > /tmp/pids.rc) >/dev/null 2>&1 &")
        cg = "/sys/fs/cgroup/system.slice/agent-runtime-pids.service"
        machine.wait_until_succeeds(f"awk '$1 == \"max\" && $2 > 0' {cg}/pids.events | grep -q .", timeout=120)
        tasks = int(machine.succeed(f"cat {cg}/pids.current"))
        events = machine.succeed(f"cat {cg}/pids.events").strip()
        print("pids.current", tasks, "pids.max", machine.succeed(f"cat {cg}/pids.max").strip(), events)
        assert tasks <= ${toString t.resources.tasksMax}, tasks
        machine.wait_until_succeeds("test -e /tmp/pids.rc", timeout=120)
        print(machine.succeed("tail -c 600 /tmp/pids.out"))
        timings["pids"] = {"pids_current": tasks, "pids_events": events, "rc": machine.succeed("cat /tmp/pids.rc").strip(), "teardown_ms": teardown("pids")}
        machine.succeed("systemctl is-system-running --wait | grep -E 'running|degraded'")

    with subtest("budget: memoryMiB ends a memory hog with an OOM kill"):
        machine.succeed(f"{F} create oom")
        status, out = machine.execute(f"{F} run oom 1000 ${hog} {opt} 2>&1")
        print(out[-1200:])
        assert status != 0, "the hog was not stopped"
        assert "Finished with result: oom-kill" in out, "no oom-kill result"
        timings["oom"] = {"memory_peak": peak(out), "teardown_ms": teardown("oom")}
        print(machine.succeed("dmesg | grep -iE 'memory cgroup out of memory|oom-kill' | tail -3"))

    with subtest("host unchanged, nothing left behind"):
        store_after = machine.succeed("ls /nix/store | wc -l; stat -c %Y /nix/store").split()
        assert store_before == store_after, (store_before, store_after)
        machine.succeed("test -f /root/host-sentinel -a -f /home/host-sentinel")
        machine.succeed("test ! -e /nix/store/agent-runtime-write-attempt")
        machine.succeed("! findmnt -rn | grep agent-runtime")
        machine.succeed("! machinectl list --no-legend | grep -q .")
        machine.succeed("! systemctl list-units --all --no-legend 'agent-runtime-*' | grep -q .")
        machine.succeed("test -z \"$(ls /var/lib/agent-runtime | grep -v '^exports$')\"")
        print("exports kept:", machine.succeed("ls /var/lib/agent-runtime/exports").split())

    print("=== measurements ===")
    print(json.dumps({"store_bind": opt, "closure": closure, "shared_namespaces": shared, "timings": timings}, indent=2))
  '';
}
