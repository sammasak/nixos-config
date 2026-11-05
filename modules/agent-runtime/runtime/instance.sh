# shellcheck shell=bash
# agent-runtime-instance: the host-side lifecycle of ephemeral nspawn instances
# (#138) over the #136 tools. create admits against the host policy, assigns,
# allocates fixed-size volumes and materializes; start runs a detached transient
# unit whose own ExecStopPost records the outcome, so nothing depends on this
# process surviving; export bundles patches, output and a bounded log; destroy
# tears down in order and releases the reservation last. An outcome that was never
# recorded (supervisor or host crash) is reported as ambiguous and never replayed.
USAGE='agent-runtime-instance [--state DIR] create ID --template MANIFEST --host POLICY --task REF [--plan PLAN.json]... | start ID [--root] [--timeout-sec N] [--idmap] [--wait] -- PROGRAM [ARG]... | wait ID [--timeout-sec N] | status [ID] | logs ID | cancel ID | export ID | destroy ID [--discard] | reconcile | record-exit ID'
state=/var/lib/agent-runtime
if [ "${1:-}" = --state ]; then
  [ $# -ge 2 ] || usage
  state=$2
  shift 2
fi
[ $# -ge 1 ] || usage
cmd=$1
shift
rundir=/run/agent-runtime
self=$(realpath "$0")
log_cap=$((1024 * 1024))
volume_names=(workspace home tmp cache output)

valid_id() { [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,40}[a-z0-9])?$ && $1 != exports ]]; }
take_id() {
  [ $# -ge 1 ] || usage
  valid_id "$1" || fail usage "instance id must be a DNS label of at most 42 characters, not \`exports\`: $1"
  id=$1
  base=$state/$id
  root=$rundir/$id/root
  unit=agent-runtime-$id.service
  machine=agent-runtime-$id
}
lock_admission() {
  mkdir -p "$state" "$rundir"
  exec 8>"$rundir/.admission.lock"
  flock -w 60 8 || fail state "the admission lock is held by another operation"
}
lock_instance() {
  exec 9>"$base/.lock"
  flock -w 60 9 || fail state "$id is locked by another operation"
}
# Every record is durable before the next step: a crash that loses a `starting` marker
# would make an interrupted run look `created`, and it could then run twice.
atomic_json() {  # FILE: stdin into FILE via a fsynced temporary sibling, then the directory
  local tmp
  tmp=$(mktemp "$1.XXXXXX")
  cat >"$tmp"
  sync "$tmp"
  mv "$tmp" "$1"
  sync "$(dirname "$1")"
}
reservations() { cat "$state"/*/reservation 2>/dev/null || true; }
vol_json() {  # the template's writable volumes as {name: {path, sizeMiB, inodes, mode, owner}}
  jq -c '.filesystem as $f | {
    workspace: {path: $f.workspace, sizeMiB: $f.workspaceBudget.sizeMiB, inodes: $f.workspaceBudget.inodes, mode: "0755", owner: 0},
    home: ($f.home + {mode: "0700", owner: 1000}), cache: ($f.cache + {mode: "0700", owner: 1000}),
    output: ($f.output + {mode: "0755", owner: 1000}), tmp: ($f.tmp + {mode: "1777", owner: 0})}' "$1"
}
mount_volumes() {  # idempotent: after a reboot the images are still there, the loop mounts are not
  local name
  for name in "${volume_names[@]}"; do
    mkdir -p "$base/vol/$name"
    mountpoint -q "$base/vol/$name" || mount -o loop,nosuid,nodev "$base/img/$name.img" "$base/vol/$name"
  done
}
build_root() {  # idempotent: the root tree lives in /run and is gone after a reboot
  local p sh
  sh=$(realpath "$(command -v bash)")
  mkdir -p "$root"/{etc/agent-runtime,bin,usr/bin,nix/store,proc,sys,dev}
  while IFS= read -r p; do mkdir -p "$root$p"; done < <(
    jq -r '(.filesystem | .workspace, .home.path, .tmp.path, .cache.path, .output.path),
           (.skills.names | keys[] | "/skills/" + .)' "$base/template.json"
    jq -r '.sources[] | select(.mode == "ro") | .path' "$base/vol/workspace/materialized.json")
  printf 'ID=agent-runtime\nPRETTY_NAME="agent-runtime %s"\n' "$(jq -r .template.name "$base/template.json")" >"$root/etc/os-release"
  printf 'root:x:0:0::/root:/bin/sh\nagent:x:1000:1000::%s:/bin/sh\nnobody:x:65534:65534::/:/bin/sh\n' \
    "$(jq -r .filesystem.home.path "$base/template.json")" >"$root/etc/passwd"
  printf 'root:x:0:\nagent:x:1000:\nnogroup:x:65534:\n' >"$root/etc/group"
  printf 'passwd: files\ngroup: files\n' >"$root/etc/nsswitch.conf"
  touch "$root/etc/agent-runtime/template.json"
  ln -sfn "$sh" "$root/bin/sh"
  ln -sfn "$(realpath "$(command -v env)")" "$root/usr/bin/env"
}
unit_active() {  # INVOCATION: the instance's unit is that invocation and not yet inactive
  local cur active
  cur=$(systemctl show -p InvocationID --value "$unit" 2>/dev/null || true)
  active=$(systemctl show -p ActiveState --value "$unit" 2>/dev/null || true)
  [ -n "$1" ] && [ "$cur" = "$1" ] && [[ $active =~ ^(active|activating|deactivating|reloading)$ ]]
}
state_of() {
  if [ ! -f "$base/instance.json" ]; then
    if [ -d "$base" ]; then echo incomplete; else echo absent; fi
  elif [ -f "$base/result.json" ]; then
    jq -r .outcome "$base/result.json"
  elif [ -f "$base/started.json" ]; then
    if unit_active "$(jq -r .invocation "$base/started.json")"; then
      if [ -e "$base/cancel-requested" ]; then echo cancelling; else echo running; fi
    else
      echo ambiguous
    fi
  elif [ -e "$base/starting" ]; then
    echo ambiguous
  else
    echo created
  fi
}
terminal() { [[ $1 =~ ^(succeeded|failed|timed-out|oom-killed|cancelled|ambiguous)$ ]]; }
status_json() {
  local s
  s=$(state_of)
  if [ "$s" = absent ]; then
    jq -nc --arg id "$id" '{id: $id, state: "absent"}'
    return
  fi
  jq -nc --arg id "$id" --arg s "$s" --arg host "$(hostname)" \
    --argjson rec "$(cat "$base/instance.json" 2>/dev/null || echo null)" \
    --argjson started "$(cat "$base/started.json" 2>/dev/null || echo null)" \
    --argjson result "$(cat "$base/result.json" 2>/dev/null || echo null)" \
    --argjson exported "$(cat "$base/exported.json" 2>/dev/null || echo null)" \
    '{schemaVersion: 1, kind: "agent-runtime-instance-status", id: $id, state: $s, host: $host}
     + (if $rec then $rec | {task, template, run, uidBase, unit, machine, volumes, createdAt} else {} end)
     + {started: $started, result: $result, export: $exported}'
}
teardown() {  # every step idempotent; a step that fails leaves the reservation, so the instance stays counted
  local name
  systemctl stop "$unit" 2>/dev/null || true
  systemctl reset-failed "$unit" 2>/dev/null || true
  if mountpoint -q "$root"; then umount -R "$root"; fi
  # a SIGKILLed nspawn leaves its per-machine directories (and the unix-export mount) behind
  for p in "/run/systemd/nspawn/$machine" "/run/systemd/nspawn/propagate/$machine"; do
    if mountpoint -q "$p/unix-export"; then umount "$p/unix-export"; fi
    if [ -d "$p" ]; then rm -rf --one-file-system "$p"; fi
  done
  for name in "${volume_names[@]}"; do
    if mountpoint -q "$base/vol/$name"; then
      timeout 30 umount "$base/vol/$name" || fail state "$id: $base/vol/$name is busy; the reservation stays until a later destroy succeeds"
    fi
  done
  rm -rf --one-file-system "$rundir/${id:?}"
  find "$base" -mindepth 1 -maxdepth 1 ! -name reservation -exec rm -rf --one-file-system {} +
  rm -f "$base/reservation"
  rmdir "$base"
}

case $cmd in
  create)
    take_id "$@"
    shift
    template='' host='' task='' plans=()
    while [ $# -gt 0 ]; do
      case $1 in
        --template) [ $# -ge 2 ] || usage; template=$2; shift 2 ;;
        --host) [ $# -ge 2 ] || usage; host=$2; shift 2 ;;
        --task) [ $# -ge 2 ] || usage; task=$2; shift 2 ;;
        --plan) [ $# -ge 2 ] || usage; plans+=(--plan "$2"); shift 2 ;;
        *) usage ;;
      esac
    done
    [ -n "$template" ] && [ -n "$host" ] && [ -n "$task" ] || usage
    [ -f "$template" ] && [ -f "$host" ] || fail usage "template or host policy not found"
    jq -e '.kind == "agent-runtime-host" and .schemaVersion == 1' "$host" >/dev/null 2>&1 \
      || fail usage "$host is not an agent-runtime-host policy, schemaVersion 1"
    name=$(jq -r .template.name "$template")
    lock_admission
    if [ -d "$base" ]; then
      [ -f "$base/instance.json" ] || fail conflict "$id is an incomplete create; run reconcile"
      jq -e --arg task "$task" --slurpfile t "$template" '.task == $task and .template.digests == $t[0].digests' \
        "$base/instance.json" >/dev/null || fail conflict "$id exists for another task or template"
      status_json
      exit 0
    fi
    jq -e --arg n "$name" '.enable and (.eligibleTemplates | index($n))' "$host" >/dev/null \
      || fail admission "template $name is not eligible on this host"
    jq -e '(.filesystem.mounts | length) == 0' "$template" >/dev/null || fail unsupported "$name: extra host mounts are not supported yet"
    jq -e '.policies.network.egress == "none"' "$template" >/dev/null || fail unsupported "$name: network egress is not supported yet (#137)"
    jq -e '(.policies.capabilities | length) == 0' "$template" >/dev/null || fail unsupported "$name: per-run credentials are not supported yet (#137)"
    jq -e '[.sources | to_entries[] | select(.value.writable) | .key as $k | .value.path == ("/workspace/" + $k)] | all' "$template" >/dev/null \
      || fail unsupported "$name: a writable source must sit at /workspace/<its name>"
    vols=$(vol_json "$template")
    mem=$(jq -r .policies.resources.memoryMiB "$template")
    disk=$(jq -r '[.[].sizeMiB] | add' <<<"$vols")
    max=$(jq -r .maxConcurrentInstances "$host")
    live=$(reservations | wc -l)
    [ "$live" -lt "$max" ] || fail admission "instances $live of $max live"
    mem_used=$(reservations | awk '{s += $1} END {print s + 0}')
    mem_total=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
    mem_reserve=$(jq -r .reserve.memoryMiB "$host")
    [ $((mem_used + mem)) -le $((mem_total - mem_reserve)) ] \
      || fail admission "memory $mem_used+$mem MiB over $mem_total-$mem_reserve MiB"
    mem_available=$(awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo)
    [ $((mem_available - mem)) -ge "$mem_reserve" ] \
      || fail admission "memory $mem MiB would leave $((mem_available - mem)) MiB available, under the $mem_reserve MiB reserve"
    disk_free=$(df --output=avail -BM "$state" | tail -1 | tr -dc 0-9)
    disk_reserve=$(jq -r .reserve.diskMiB "$host")
    [ $((disk + disk_reserve)) -le "$disk_free" ] || fail admission "disk $disk+$disk_reserve MiB over $disk_free MiB free"
    uidbase=''
    for slot in $(seq 0 63); do
      b=$((1048576 + 65536 * slot))
      if ! reservations | awk -v b="$b" '$3 == b {f = 1} END {exit !f}'; then
        uidbase=$b
        break
      fi
    done
    [ -n "$uidbase" ] || fail admission "no free UID range"
    mkdir -p "$base/img" "$base/vol"
    echo "$mem $disk $uidbase $name" | atomic_json "$base/reservation"
    trap 'trap - ERR; echo "create $id failed, rolling back" >&2; teardown 2>/dev/null || true' EXIT
    cp "$template" "$base/template.json"
    cp "$host" "$base/host.json"
    run_capture state "assign failed" agent-runtime-assign --template "$template" --run "$id" --out "$base/run" "${plans[@]}"
    for vname in "${volume_names[@]}"; do
      v=$(jq -c --arg n "$vname" '.[$n]' <<<"$vols")
      owner=$((uidbase + $(jq -r .owner <<<"$v")))
      fallocate -l "$(jq -r .sizeMiB <<<"$v")M" "$base/img/$vname.img"
      # nodiscard: the default discard would punch the allocation back out of the image
      mkfs.ext4 -q -F -m 0 -N "$(jq -r .inodes <<<"$v")" -E "nodiscard,root_owner=$owner:$owner" "$base/img/$vname.img"
    done
    mount_volumes
    for vname in "${volume_names[@]}"; do
      rmdir "$base/vol/$vname/lost+found"
      chmod "$(jq -r --arg n "$vname" '.[$n].mode' <<<"$vols")" "$base/vol/$vname"
    done
    run_capture state "materialize failed" agent-runtime-materialize --run "$base/run" --template "$template" --root "$base/vol/workspace"
    chown -R "$((uidbase + 1000)):$((uidbase + 1000))" "$base/vol/workspace/workspace"
    chmod 0755 "$base/vol/workspace/workspace"
    build_root
    for vname in "${volume_names[@]}"; do sync -f "$base/vol/$vname"; done
    sync -f "$base"
    jq -n --arg id "$id" --arg task "$task" --arg host "$(hostname)" --arg at "$(now)" --argjson uid "$uidbase" \
      --arg unit "$unit" --arg machine "$machine" --argjson vols "$vols" --arg b "$base" \
      --slurpfile t "$template" --slurpfile r "$base/run/run.json" '
      {schemaVersion: 1, kind: "agent-runtime-instance-record", id: $id, task: $task, host: $host,
       template: {name: $t[0].template.name, digests: $t[0].digests}, run: {digest: $r[0].digests.run},
       uidBase: $uid, unit: $unit, machine: $machine, createdAt: $at,
       volumes: ($vols | with_entries(.value |= {path, sizeMiB, inodes} + {image: ($b + "/img/" + .key + ".img"), mount: ($b + "/vol/" + .key)}))}' \
      | atomic_json "$base/instance.json"
    trap - EXIT
    status_json
    ;;

  start)
    take_id "$@"
    shift
    uid=1000 timeout_sec='' opt='' wait=0
    while [ $# -gt 0 ]; do
      case $1 in
        --root) uid=0; shift ;;
        --timeout-sec) [ $# -ge 2 ] || usage; timeout_sec=$2; shift 2 ;;
        --idmap) opt=:idmap; shift ;;
        --wait) wait=1; shift ;;
        --) shift; break ;;
        *) usage ;;
      esac
    done
    [ $# -ge 1 ] || usage
    [ -d "$base" ] || fail state "$id does not exist"
    lock_instance
    s=$(state_of)
    case $s in
      created) ;;
      running | cancelling | succeeded | failed | timed-out | oom-killed | cancelled)
        echo "$id is already $s; a start is not repeated" >&2
        status_json
        exit 0 ;;
      ambiguous) fail ambiguous "$id was started and its outcome was never recorded; it is reported, not replayed" ;;
      *) fail state "$id is $s" ;;
    esac
    t=$base/template.json
    limit=$(( $(jq -r .policies.resources.timeoutMinutes "$t") * 60 ))
    if [ -n "$timeout_sec" ]; then
      [[ $timeout_sec =~ ^[1-9][0-9]*$ ]] && [ "$timeout_sec" -le "$limit" ] || fail usage "--timeout-sec must be 1..$limit (the template's timeoutMinutes)"
      limit=$timeout_sec
    fi
    uidbase=$(awk '{print $3}' "$base/reservation")
    mount_volumes
    build_root
    path=$(jq -r '[.packages[].storePath + "/bin"] | join(":")' "$t")
    binds=(--bind-ro="/nix/store:/nix/store$opt" --bind-ro="$base/template.json:/etc/agent-runtime/template.json")
    while IFS=$'\t' read -r from to; do binds+=(--bind-ro="$from:$to$opt"); done < <(
      jq -r '.skills.names | to_entries[] | [.value.path, "/skills/" + .key] | @tsv' "$t"
      jq -r '.sources[] | select(.mode == "ro") | [.storePath, .path] | @tsv' "$base/vol/workspace/materialized.json")
    binds+=(--bind="$base/vol/workspace/workspace:$(jq -r .filesystem.workspace "$t")")
    for vname in home tmp cache output; do
      binds+=(--bind="$base/vol/$vname:$(jq -r --arg n "$vname" '.filesystem[$n].path' "$t")")
    done
    # nspawn's default bounding set minus SETUID, SETGID and SETPCAP, which setpriv needs
    # to switch user and empty the bounding set before the payload runs
    drop=CAP_CHOWN,CAP_DAC_OVERRIDE,CAP_DAC_READ_SEARCH,CAP_FOWNER,CAP_FSETID,CAP_KILL,CAP_LINUX_IMMUTABLE
    drop+=,CAP_NET_BIND_SERVICE,CAP_NET_BROADCAST,CAP_NET_ADMIN,CAP_NET_RAW,CAP_IPC_OWNER,CAP_SYS_CHROOT,CAP_SYS_PTRACE
    drop+=,CAP_SYS_ADMIN,CAP_SYS_BOOT,CAP_SYS_NICE,CAP_SYS_RESOURCE,CAP_SYS_TTY_CONFIG,CAP_MKNOD,CAP_LEASE
    drop+=,CAP_AUDIT_WRITE,CAP_AUDIT_CONTROL,CAP_SETFCAP
    args=(systemd-run --unit="$unit" --collect --service-type=exec --quiet
      --description="agent-runtime instance $id ($(jq -r .task "$base/instance.json"))"
      -p MemoryMax="$(jq -r .policies.resources.memoryMiB "$t")M" -p MemorySwapMax=0
      -p TasksMax="$(jq -r .policies.resources.tasksMax "$t")"
      -p CPUQuota="$(( $(jq -r .policies.resources.cpus "$t") * 100 ))%"
      -p RuntimeMaxSec="$limit" -p KillMode=mixed -p TimeoutStopSec=30
      # nspawn builds a cgroup subtree under the unit; with Delegate systemd runs ExecStopPost in
      # .control, without it the hook cannot be spawned (EBUSY) and the outcome is lost
      -p Delegate=yes
      -p ExecStopPost="$self --state $state record-exit $id"
      # console: stderr is the unit's journal stream, so nspawn's own errors carry the invocation id
      --setenv=SYSTEMD_LOG_TARGET=console
      systemd-nspawn --quiet --keep-unit --settings=no --register=yes --console=pipe
        -M "$machine" -D "$root"
        --private-users="$uidbase:65536" --private-users-ownership=chown
        --private-network --as-pid2 --resolv-conf=off --timezone=off --no-new-privileges=yes
        --drop-capability="$drop"
        "${binds[@]}"
        --setenv=PATH="$path" --setenv=HOME="$(jq -r .filesystem.home.path "$t")"
        --setenv=TMPDIR="$(jq -r .filesystem.tmp.path "$t")" --setenv=AGENT_RUNTIME_INSTANCE="$id"
        --setenv=AGENT_RUNTIME_OUTPUT="$(jq -r .filesystem.output.path "$t")"
        -- "$(realpath "$(command -v setpriv)")" --reuid="$uid" --regid="$uid" --clear-groups
        --bounding-set=-all --inh-caps=-all --no-new-privs -- "$@")
    printf -v command '%q ' "$@"
    # the marker comes first: a crash between it and the unit is reported as ambiguous, never re-run
    jq -nc --arg at "$(now)" '{at: $at}' | atomic_json "$base/starting"
    systemctl reset-failed "$unit" 2>/dev/null || true
    run_capture state "systemd-run failed" "${args[@]}"
    invocation=$(systemctl show -p InvocationID --value "$unit" 2>/dev/null || true)
    leader=''
    for _ in $(seq 1 50); do
      leader=$(machinectl show -p Leader --value "$machine" 2>/dev/null || true)
      [ -z "$leader" ] || break
      sleep 0.1
    done
    ns='{}' uid_map=null
    if [ -n "$leader" ]; then
      for n in user mnt pid ipc uts net cgroup time; do
        ns=$(jq -c --arg n "$n" --arg v "$(readlink "/proc/$leader/ns/$n" 2>/dev/null || true)" '.[$n] = $v' <<<"$ns")
      done
      uid_map=$(jq -Rc 'split(" ") | map(select(length > 0) | tonumber)' <"/proc/$leader/uid_map" 2>/dev/null || echo null)
    fi
    jq -nc --arg at "$(jq -r .at "$base/starting")" --arg inv "$invocation" --argjson uid "$uid" --argjson timeout "$limit" \
      --arg command "${command% }" --arg cg "$(systemctl show -p ControlGroup --value "$unit" 2>/dev/null || true)" \
      --arg leader "$leader" --argjson ns "$ns" --argjson map "$uid_map" --arg store "${opt:-plain}" \
      '{startedAt: $at, invocation: $inv, uid: $uid, timeoutSec: $timeout, command: $command, controlGroup: $cg,
        leaderPid: ($leader | if . == "" then null else tonumber end), namespaces: $ns, uidMap: $map, storeBind: $store}' \
      | atomic_json "$base/started.json"
    exec 9>&-
    if [ "$wait" = 1 ]; then exec "$self" --state "$state" wait "$id"; fi
    status_json
    ;;

  record-exit)  # ExecStopPost of the instance's unit; never takes the instance lock (cancel holds it while stopping)
    take_id "$@"
    [ -f "$base/instance.json" ] || exit 0
    service_result=${SERVICE_RESULT:-unknown} exit_code=${EXIT_CODE:-} exit_status=${EXIT_STATUS:-}
    # the unit is still loaded during ExecStopPost: its accounting is read here, before --collect drops it
    show() { systemctl show -p "$1" --value "$unit" 2>/dev/null || true; }
    # the kernel's count, not SERVICE_RESULT: with Delegate the payload often exits (137) before
    # systemd acts on the OOM event, and the unit's result is then exit-code
    oom_kills=$(awk '$1 == "oom_kill" {print $2}' "/sys/fs/cgroup$(show ControlGroup)/memory.events" 2>/dev/null || echo 0)
    if [ -e "$base/cancel-requested" ]; then outcome=cancelled
    elif [ "$service_result" = timeout ]; then outcome=timed-out
    elif [ "$service_result" = success ] && [ "$exit_code" = exited ] && [ "$exit_status" = 0 ]; then outcome=succeeded
    elif [ "$service_result" = oom-kill ] || [ "${oom_kills:-0}" -gt 0 ]; then outcome=oom-killed
    else outcome=failed
    fi
    started_us=$(show ExecMainStartTimestampMonotonic) exited_us=$(show ExecMainExitTimestampMonotonic)
    jq -nc --arg o "$outcome" --arg r "$service_result" --arg c "$exit_code" --arg s "$exit_status" --arg at "$(now)" \
      --arg inv "${INVOCATION_ID:-}" --arg peak "$(show MemoryPeak)" --arg cpu "$(show CPUUsageNSec)" \
      --arg a "$started_us" --arg b "$exited_us" --arg oom "${oom_kills:-0}" '
      def num: tonumber? // null;
      {outcome: $o, serviceResult: $r, exitCode: $c, exitStatus: ($s | tonumber? // $s), finishedAt: $at, invocation: $inv,
       memoryPeakBytes: ($peak | num), cpuUsageNSec: ($cpu | num), oomKills: ($oom | num),
       runtimeUSec: (if ($a | num) and ($b | num) and ($b | num) > 0 then ($b | num) - ($a | num) else null end)}' \
      | atomic_json "$base/result.json"
    ;;

  wait)
    take_id "$@"
    shift
    deadline=''
    if [ "${1:-}" = --timeout-sec ]; then
      [ $# -ge 2 ] || usage
      deadline=$(( $(date +%s) + $2 ))
    fi
    while :; do
      s=$(state_of)
      if terminal "$s" || [ "$s" = absent ]; then break; fi
      if [ -n "$deadline" ] && [ "$(date +%s)" -ge "$deadline" ]; then fail state "$id is still $s"; fi
      sleep 0.5
    done
    status_json
    [ "$s" = succeeded ] || exit 1
    ;;

  logs)  # the payload's journal for its one invocation, the last 1 MiB
    take_id "$@"
    inv=$(jq -r '.invocation // empty' "$base/started.json" 2>/dev/null || true)
    [ -n "$inv" ] || fail state "$id has not been started"
    journalctl --sync 2>/dev/null || true
    journalctl -o cat --no-pager "_SYSTEMD_INVOCATION_ID=$inv" | tail -c "$log_cap"
    ;;

  status)
    if [ $# -ge 1 ]; then
      take_id "$@"
      status_json
    else
      mkdir -p "$state"
      for d in "$state"/*/; do
        n=$(basename "$d")
        if valid_id "$n"; then take_id "$n"; status_json; fi
      done | jq -sc .
    fi
    ;;

  cancel)
    take_id "$@"
    [ -d "$base" ] || { status_json; exit 0; }
    lock_instance
    s=$(state_of)
    case $s in
      created)
        : | atomic_json "$base/cancel-requested"
        jq -nc --arg at "$(now)" '{outcome: "cancelled", serviceResult: "never-started", exitCode: "", exitStatus: "", finishedAt: $at}' \
          | atomic_json "$base/result.json" ;;
      running | cancelling)
        : | atomic_json "$base/cancel-requested"
        systemctl stop "$unit" || true ;;
      *) echo "$id is $s; nothing to cancel" >&2 ;;
    esac
    status_json
    ;;

  export)
    take_id "$@"
    [ -d "$base" ] || fail state "$id does not exist"
    lock_instance
    s=$(state_of)
    if [ -f "$base/exported.json" ]; then status_json; exit 0; fi
    terminal "$s" || fail conflict "$id is $s; export after it has ended"
    mount_volumes
    out=$state/exports/$id
    [ ! -e "$out" ] || fail conflict "$out exists but $id has no export record"
    mkdir -p "$state/exports"
    tmp=$(mktemp -d "$state/exports/.$id.XXXXXX")
    trap 'rm -rf "$tmp"' EXIT
    ws=$base/vol/workspace
    if [ -f "$ws/export-pending" ]; then
      run_capture export "source export failed" agent-runtime-export --root "$ws" --out "$tmp/sources"
    fi
    cap=$(( $(jq -r .filesystem.output.sizeMiB "$base/template.json") * 1024 * 1024 ))
    omitted='[]'
    for p in "$tmp"/sources/*.patch; do
      [ -e "$p" ] || continue
      if [ "$(stat -c %s "$p")" -gt "$cap" ]; then
        omitted=$(jq -c --arg p "$(basename "$p")" --argjson b "$(stat -c %s "$p")" '. + [{patch: $p, bytes: $b}]' <<<"$omitted")
        rm "$p"
      fi
    done
    cp -r "$base/vol/output/." "$tmp/output"
    inv=$(jq -r '.invocation // empty' "$base/started.json" 2>/dev/null || true)
    log_bytes=0 truncated=false
    if [ -n "$inv" ]; then
      journalctl --sync 2>/dev/null || true
      journalctl -o cat --no-pager "_SYSTEMD_INVOCATION_ID=$inv" >"$tmp/run.log" 2>/dev/null || true
      log_bytes=$(stat -c %s "$tmp/run.log")
      if [ "$log_bytes" -gt "$log_cap" ]; then
        tail -c "$log_cap" "$tmp/run.log" >"$tmp/run.log.tail"
        mv "$tmp/run.log.tail" "$tmp/run.log"
        truncated=true
      fi
    fi
    for f in instance.json started.json result.json; do
      if [ -f "$base/$f" ]; then cp "$base/$f" "$tmp/$f"; fi
    done
    files=$(cd "$tmp" && find . -type f -printf '%P\n' | sort | while IFS= read -r f; do
      jq -nc --arg f "$f" --arg s "$(sha256sum "$f" | cut -d' ' -f1)" --argjson b "$(stat -c %s "$f")" '{path: $f, sha256: $s, bytes: $b}'
    done | jq -sc .)
    jq -n --arg id "$id" --arg s "$s" --arg at "$(now)" --argjson files "$files" --argjson omitted "$omitted" \
      --argjson lb "$log_bytes" --argjson tr "$truncated" --slurpfile rec "$base/instance.json" \
      '{schemaVersion: 1, kind: "agent-runtime-instance-export", id: $id, task: $rec[0].task, template: $rec[0].template,
        outcome: $s, recovery: ($s != "succeeded"), exportedAt: $at, log: {bytes: $lb, truncatedTo: (if $tr then 1048576 else null end)},
        omittedPatches: $omitted, files: $files}' >"$tmp/bundle.json"
    sync -f "$tmp"
    mv "$tmp" "$out"
    sync "$state/exports"
    trap - EXIT
    jq -nc --arg out "$out" --arg at "$(now)" --arg s "$s" '{dir: $out, at: $at, outcome: $s}' | atomic_json "$base/exported.json"
    status_json
    ;;

  destroy)
    take_id "$@"
    shift
    discard=0
    [ "${1:-}" != --discard ] || discard=1
    [ -d "$base" ] || { status_json; exit 0; }
    lock_admission
    lock_instance
    s=$(state_of)
    case $s in
      running | cancelling) fail conflict "$id is $s; cancel it first" ;;
      incomplete) ;;
      *)
        if [ ! -f "$base/exported.json" ] && [ "$discard" = 0 ] && [ -e "$base/starting" ]; then
          fail conflict "$id ($s) has not been exported; export it, or destroy --discard"
        fi
        if [ -f "$base/vol/workspace/materialized.json" ] && [ "$discard" = 0 ] && [ -f "$base/exported.json" ]; then
          mount_volumes
          run_capture state "reclaim refused" agent-runtime-reclaim --root "$base/vol/workspace"
        fi ;;
    esac
    teardown
    jq -nc --arg id "$id" --arg was "$s" '{id: $id, state: "destroyed", was: $was}'
    ;;

  reconcile)  # report every instance; roll back creates that never finished; start or re-run nothing
    lock_admission
    for d in "$state"/*/; do
      [ -d "$d" ] || continue
      n=$(basename "$d")
      valid_id "$n" || continue
      take_id "$n"
      s=$(state_of)
      if [ "$s" = incomplete ]; then
        teardown
        jq -nc --arg id "$id" '{id: $id, state: "rolled-back", reason: "create never finished"}'
      else
        status_json | jq -c '{id, state, task, unit, started: (.started | if . then {invocation, startedAt} else null end)}'
      fi
    done | jq -sc .
    ;;

  *) usage ;;
esac
