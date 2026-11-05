# M0 proof for the ephemeral nspawn agent runtime (#135): one typed template
# (one pinned GitHub Rust repo, one named skill, Nix packages, declared paths)
# materialised as user-namespaced systemd-nspawn instances by a transient-unit
# factory, never by a host switch or a static containers.<name> entry. Runs
# only in QEMU: nix build .#packages.x86_64-linux.agent-runtime-nspawn
{ pkgs, rfProto, skills }:
let
  template = {
    name = "rust-worker-m0";
    repository = {
      github = "sammasak/rf-proto";
      ref = { type = "commit"; value = rfProto.rev; };
      source = rfProto;
      path = "/workspace/rf-proto";
      writable = true;
    };
    skill = {
      name = "rust-engineering";
      source = "${skills}/skills/rust-engineering";
      path = "/skills/rust-engineering";
    };
    packages = with pkgs; [ bash coreutils findutils gnugrep gnused gawk diffutils util-linux cargo rustc gcc ];
    filesystem = { workspace = "/workspace"; home = "/home/agent"; tmp = "/tmp"; export = "/workspace/export"; };
    budget = { memoryMax = "1G"; tasksMax = 512; cpuQuota = "200%"; };
  };
  env = pkgs.buildEnv { name = "agent-runtime-${template.name}"; paths = template.packages; };
  closure = pkgs.closureInfo { rootPaths = [ env template.repository.source template.skill.source ]; };

  # Runs as root inside the instance: records the boundary and tries to break it.
  probe = pkgs.writeShellScript "agent-probe" ''
    set -u
    export PATH=${env}/bin
    echo "uid_map: $(cat /proc/self/uid_map | tr -s ' ')"
    echo "caps: $(grep -E '^Cap(Eff|Bnd)' /proc/self/status | tr -s '\t ' ' ' | tr '\n' ' ')"
    echo "nonewprivs: $(grep NoNewPrivs /proc/self/status)"
    echo "mounts:"; findmnt -rn -o TARGET,FSTYPE,OPTIONS | sed 's/^/  /'
    echo "dev: $(ls /dev | tr '\n' ' ')"
    echo "net: $(ls /sys/class/net | tr '\n' ' ')"
    echo "store_owner: $(stat -c '%u:%g %A' ${env})"
    fail=0
    chk() { if "$@"; then echo "ok   $*"; else echo "FAIL $*"; fail=1; fi; }
    chk test ! -e /nix/var/nix/daemon-socket/socket
    chk test ! -S /run/systemd/private
    chk test ! -e /run/docker.sock
    chk test ! -e /home/lukas
    chk test ! -e /root/host-sentinel
    chk test -z "''${SSH_AUTH_SOCK:-}"
    chk test "$(ls /sys/class/net)" = lo
    chk test -d ${template.skill.path}
    chk test -f ${template.skill.path}/SKILL.md
    chk test -f /src/rf-proto/Cargo.toml
    chk test "$(cat /proc/self/uid_map | awk '{print $2}')" != 0
    deny() { if "$@" 2>/dev/null; then echo "FAIL (succeeded) $*"; fail=1; else echo "denied $*"; fi; }
    deny touch /nix/store/agent-runtime-write-attempt
    deny touch ${env}/bin/agent-runtime-write-attempt
    deny touch /src/rf-proto/agent-runtime-write-attempt
    deny touch ${template.skill.path}/agent-runtime-write-attempt
    deny mount -o remount,rw /nix/store
    deny mount -o remount,rw /src/rf-proto
    deny mount -o remount,rw /
    deny mknod /dev/sda b 8 0
    deny sh -c 'echo 1 > /proc/sys/kernel/sysrq'
    chk sh -c 'echo probe > ${template.filesystem.workspace}/probe.txt'
    chk sh -c 'echo probe > ${template.filesystem.tmp}/probe.txt'
    exit $fail
  '';

  # Runs as the unprivileged user `agent`: the real workload and the export.
  work = pkgs.writeShellScript "agent-work" ''
    set -euo pipefail
    echo "started_ns=$(date +%s%N)"
    export PATH=${env}/bin HOME=${template.filesystem.home} TMPDIR=${template.filesystem.tmp}
    export CARGO_HOME=$HOME/.cargo
    echo "whoami=$(id -u):$(id -g) home_owner=$(stat -c %u $HOME) tmp_mode=$(stat -c %a $TMPDIR)"
    cp -r /src/rf-proto ${template.repository.path}
    chmod -R u+w ${template.repository.path}
    cd ${template.repository.path}
    cargo test --offline 2>&1 | tee ${template.filesystem.export}/cargo-test.log
    test "''${PIPESTATUS[0]}" = 0
    bin=$(find target/debug/deps -maxdepth 1 -type f -perm -u+x -name 'rf_proto-*' | head -1)
    cp "$bin" ${template.filesystem.export}/rf_proto-test
    (cd ${template.filesystem.export} && sha256sum rf_proto-test > rf_proto-test.sha256)
    printf 'template=%s\nrepository=%s\nref=%s:%s\nskill=%s\nenv=%s\n' \
      ${template.name} ${template.repository.github} ${template.repository.ref.type} \
      ${template.repository.ref.value} ${template.skill.name} ${env} > ${template.filesystem.export}/manifest.txt
    if touch /nix/store/agent-runtime-write-attempt 2>/dev/null; then echo "FAIL store writable"; exit 1; fi
    if touch /src/rf-proto/x 2>/dev/null; then echo "FAIL source writable"; exit 1; fi
    echo "finished_ns=$(date +%s%N)"
  '';

  # The factory: one ephemeral instance per call, a transient service unit,
  # fixed UID range per instance, everything it touches under its id.
  factory = pkgs.writeShellScript "agent-runtime" ''
    set -euo pipefail
    cmd=$1; id=$2; shift 2
    base=/var/lib/agent-runtime/$id
    root=/run/agent-runtime/$id/root
    uidbase=$((1048576 + 65536 * $(printf '%s' "$id" | cksum | cut -d' ' -f1) % 64))
    case $cmd in
      create)
        mkdir -p "$base/workspace/export" "$root"/{etc,bin,usr/bin,nix/store,src/rf-proto,skills/rust-engineering,workspace,home/agent,tmp,proc,sys,dev,run}
        printf 'ID=agent-runtime\nPRETTY_NAME="agent-runtime ${template.name}"\n' > "$root/etc/os-release"
        printf 'root:x:0:0::/root:/bin/sh\nagent:x:1000:1000::${template.filesystem.home}:/bin/sh\nnobody:x:65534:65534::/:/bin/sh\n' > "$root/etc/passwd"
        printf 'root:x:0:\nagent:x:1000:\nnogroup:x:65534:\n' > "$root/etc/group"
        ln -sf ${pkgs.bash}/bin/bash "$root/bin/sh"
        ln -sf ${pkgs.coreutils}/bin/env "$root/usr/bin/env"
        chown -R $((uidbase + 1000)):$((uidbase + 1000)) "$base/workspace"
        echo "$uidbase" > "$base/uidbase"
        ;;
      run)  # run <id> <user> <script> [store-bind-opt]
        user=$1; script=$2; opt=''${3:-}
        systemd-run --unit="agent-runtime-$id" --wait --pipe --quiet \
          -p MemoryMax=${template.budget.memoryMax} -p TasksMax=${toString template.budget.tasksMax} -p CPUQuota=${template.budget.cpuQuota} \
          -p KillMode=mixed \
          ${pkgs.systemd}/bin/systemd-nspawn --quiet --keep-unit --settings=no --register=yes \
            -M "agent-runtime-$id" -D "$root" \
            --private-users="$uidbase:65536" --private-users-ownership=chown \
            --private-network --as-pid2 --resolv-conf=off --timezone=off \
            --bind-ro="/nix/store:/nix/store$opt" \
            --bind-ro="${template.repository.source}:/src/rf-proto$opt" \
            --bind-ro="${template.skill.source}:${template.skill.path}$opt" \
            --bind="$base/workspace:${template.filesystem.workspace}" \
            --tmpfs="${template.filesystem.tmp}:mode=1777,size=256M" \
            --tmpfs="${template.filesystem.home}:mode=0755,uid=1000,gid=1000,size=256M" \
            --user="$user" "$script"
        ;;
      export)
        mkdir -p /var/lib/agent-runtime/exports
        cp -r "$base/workspace/export" "/var/lib/agent-runtime/exports/$id"
        (cd "/var/lib/agent-runtime/exports/$id" && sha256sum -c rf_proto-test.sha256)
        ;;
      destroy)
        systemctl stop "agent-runtime-$id.service" 2>/dev/null || true
        systemctl reset-failed "agent-runtime-$id.service" 2>/dev/null || true
        mountpoint -q "$root" && umount -R "$root" || true
        rm -rf "$base" "/run/agent-runtime/$id"
        ;;
      check-clean)
        findmnt -rn | grep -c "agent-runtime/$id" | grep -qx 0
        ! systemctl list-units --all --no-legend "agent-runtime-$id.service" | grep -q .
        ! machinectl list --no-legend | grep -q "agent-runtime-$id"
        ! pgrep -f "agent-runtime-$id" >/dev/null
        test ! -e "$base" && test ! -e "/run/agent-runtime/$id"
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
    environment.systemPackages = with pkgs; [ util-linux procps gnugrep gawk coreutils ];
  };

  testScript = ''
    import json, re, time
    machine.wait_for_unit("multi-user.target")
    print("=== versions ===")
    print(machine.succeed("uname -r; systemctl --version | head -1; ${pkgs.systemd}/bin/systemd-nspawn --version | head -1"))
    print("nixpkgs ${pkgs.lib.version}; rf-proto ${rfProto.rev}; skills ${skills.rev or "unpinned"}")
    print("closure paths:", machine.succeed("wc -l < ${closure}/store-paths").strip(),
          "total nar bytes:", machine.succeed("cat ${closure}/total-nar-size").strip())
    machine.succeed("touch /root/host-sentinel")
    store_before = machine.succeed("ls /nix/store | wc -l; stat -c %Y /nix/store").split()

    # the store bind: idmap when the backing filesystem allows it, else plain
    machine.succeed("${factory} create probe")
    status, out = machine.execute("${factory} run probe root ${pkgs.coreutils}/bin/true :idmap")
    opt = ":idmap" if status == 0 else ""
    print("=== store bind option:", repr(opt), "(idmap probe exit", status, ")", out[-300:])

    with subtest("probe as container root: boundary visible, store and sources read-only"):
        out = machine.succeed(f"${factory} run probe root ${probe} {opt}")
        print(out)
        assert "FAIL" not in out
        machine.succeed("${factory} destroy probe && ${factory} check-clean probe")

    timings = {}
    for run in ("cold", "warm"):
        with subtest(f"{run}: create -> run cargo test as agent -> export -> destroy"):
            t0 = time.monotonic_ns()
            machine.succeed(f"${factory} create {run}")
            status, out = machine.execute(f"${factory} run {run} agent ${work} {opt} 2>&1; echo exit=$?")
            t1 = time.monotonic_ns()
            print(out[-2500:])
            assert out.rstrip().endswith("exit=0"), "workload failed"
            assert re.search(r"test result: ok\. \d+ passed", out), "cargo test did not report a pass"
            started = int(re.search(r"started_ns=(\d+)", out).group(1))
            finished = int(re.search(r"finished_ns=(\d+)", out).group(1))
            wall_start = int(machine.succeed("date +%s%N")) - (time.monotonic_ns() - t0)
            timings[run] = {"startup_ms": (started - wall_start) // 1000000, "work_ms": (finished - started) // 1000000, "total_ms": (t1 - t0) // 1000000}
            mem = machine.succeed(f"systemctl show -p MemoryPeak -p CPUUsageNSec agent-runtime-{run}.service || true")
            timings[run]["unit"] = mem.replace("\n", " ")
            print(machine.succeed(f"${factory} export {run}"))
            print(machine.succeed(f"cat /var/lib/agent-runtime/exports/{run}/manifest.txt"))
            machine.succeed(f"${factory} destroy {run}")
            machine.succeed(f"${factory} check-clean {run}")
            t2 = time.monotonic_ns()
            timings[run]["teardown_ms"] = (t2 - t1) // 1000000

    with subtest("host unchanged, nothing left behind"):
        store_after = machine.succeed("ls /nix/store | wc -l; stat -c %Y /nix/store").split()
        assert store_before == store_after, (store_before, store_after)
        machine.succeed("test -f /root/host-sentinel")
        machine.succeed("test ! -e /nix/store/agent-runtime-write-attempt")
        machine.succeed("! findmnt -rn | grep agent-runtime")
        machine.succeed("! machinectl list --no-legend | grep -q .")
        machine.succeed("! systemctl list-units --all --no-legend 'agent-runtime-*' | grep -q .")
        print("exports kept:", machine.succeed("ls /var/lib/agent-runtime/exports").split())

    print("=== measurements ===")
    print(json.dumps({"store_bind": opt, "timings": timings}, indent=2))
  '';
}
