# The #139 runtime fixture shared by the single-host and the two-node Herdr tests: two templates,
# a fixture agent that reads handoffs from its PTY and reports through a status file, and the
# launch/prepare/destroy around systemd-nspawn. The adapter under test is the shipped one.
{ pkgs, lib, skills }:
let
  runtime = import ../modules/agent-runtime/lib.nix { inherit lib pkgs; };
  template = name: pkgs': {
    role = { inherit name; harness = "claude-code"; };
    skillsSource = skills;
    skills.lean-code = { };
    packages = pkgs';
    filesystem = {
      home.sizeMiB = 16;
      tmp.sizeMiB = 16;
      cache.sizeMiB = 16;
      output.sizeMiB = 16;
    };
    resources = { cpus = 1; memoryMiB = 128; tasksMax = 64; timeoutMinutes = 5; };
  };
  evaluated = runtime.evalManifests {
    modules = [
      {
        sam.agentRuntime.host = { enable = true; eligibleTemplates = [ "worker-a" "worker-b" ]; maxConcurrentInstances = 2; };
        sam.agentRuntime.templates.worker-a = template "worker-a" (with pkgs; [ bash coreutils ]);
        sam.agentRuntime.templates.worker-b = template "worker-b" (with pkgs; [ bash coreutils gnugrep ]);
      }
    ];
  };
  manifest = n: "${evaluated.manifestDir}/${n}.json";
  adapter = import ../modules/agent-runtime/herdr { inherit pkgs; };
  agentEnv = pkgs.buildEnv { name = "rt-fixture-agent"; paths = with pkgs; [ bash coreutils ]; };

  # The fixture agent inside the container: what a harness does, reduced to its
  # lifecycle. It reads each handoff from its PTY and reports through a status
  # file in its own output mount; it has no Herdr socket and no network.
  agent = pkgs.writeShellScript "rt-fixture-agent" ''
    export PATH=${agentEnv}/bin
    st=/output/status
    echo started >> $st
    sleep 1
    echo idle >> $st
    n=0
    while IFS= read -r line; do
      case $line in
        "") continue ;;
        EXIT) echo finished >> $st; exit 0 ;;
        BLOCK) echo blocked >> $st; continue ;;
        UNBLOCK) echo idle >> $st; continue ;;
      esac
      n=$((n + 1))
      echo working >> $st
      printf '%s\n' "$line" > /output/handoff-$n.txt
      sleep 2
      echo "result $n of $(id -u) in $(cat /proc/sys/kernel/hostname)" > /output/result-$n.txt
      echo idle >> $st
    done
  '';

  # The pane command: a cgroup-bounded scope around nspawn with the PTY as its
  # console, the only channel between Herdr and the container. #138's adapter
  # supplies the production form; #135/#137 prove the boundary itself.
  launch = pkgs.writeShellScript "rt-launch" ''
    set -euo pipefail
    id=$1 uidbase=$2
    exec ${pkgs.systemd}/bin/systemd-run --scope --quiet --unit="rt-$id" -p MemoryMax=128M -p TasksMax=64 \
      ${pkgs.systemd}/bin/systemd-nspawn --quiet --keep-unit --console=interactive --settings=no --register=yes \
        -M "rt-$id" -D "/run/rt/$id/root" \
        --private-users="$uidbase:65536" --private-users-ownership=chown \
        --private-network --as-pid2 --resolv-conf=off --timezone=off --no-new-privileges=yes \
        --hostname="rt-$id" \
        --bind-ro=/nix/store --bind="/var/lib/rt/$id/output:/output" \
        /bin/sh -c "exec ${pkgs.util-linux}/bin/setpriv --reuid=1000 --regid=1000 --clear-groups --bounding-set=-all --no-new-privs ${agent}"
  '';

  prepare = pkgs.writeShellScript "rt-prepare" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath (with pkgs; [ coreutils ])}
    id=$1 uidbase=$2
    root=/run/rt/$id/root
    mkdir -p "$root"/{etc,bin,usr/bin,nix/store,output,proc,sys,dev} "/var/lib/rt/$id/output"
    printf 'root:x:0:0::/root:/bin/sh\nagent:x:1000:1000::/:/bin/sh\n' > "$root/etc/passwd"
    printf 'root:x:0:\nagent:x:1000:\n' > "$root/etc/group"
    printf 'ID=agent-runtime\n' > "$root/etc/os-release"
    ln -sf ${pkgs.bash}/bin/bash "$root/bin/sh"
    chown $((uidbase + 1000)):$((uidbase + 1000)) "/var/lib/rt/$id/output"
  '';

  destroy = pkgs.writeShellScript "rt-destroy" ''
    export PATH=${lib.makeBinPath (with pkgs; [ coreutils systemd util-linux ])}
    id=$1
    machinectl terminate "rt-$id" 2>/dev/null || true
    systemctl stop "rt-$id.scope" 2>/dev/null || true
    for _ in $(seq 50); do machinectl show "rt-$id" >/dev/null 2>&1 || break; sleep 0.1; done
    rm -rf "/run/rt/$id"
  '';
in
{
  inherit evaluated manifest adapter agent launch prepare destroy;
}
