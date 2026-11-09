# shellcheck shell=bash
# agent-runtime-instance: the host-side lifecycle of ephemeral nspawn instances
# (#138) over the #136 tools. create admits against the host policy, assigns,
# allocates fixed-size volumes and materializes; start runs a detached transient
# unit whose own ExecStopPost records the outcome, so nothing depends on this
# process surviving; export bundles patches, output and a bounded log; destroy
# tears down in order and releases the reservation last. An outcome that was never
# recorded (supervisor or host crash) is reported as ambiguous and never replayed.
USAGE='agent-runtime-instance [--state DIR] create ID --template MANIFEST [--host POLICY] --task REF [--plan PLAN.json]... | start ID [--request REQUEST.json] [--root] [--timeout-sec N] [--idmap] [--credential FILE | --credential-issuer PROGRAM [--credential-ttl SEC]] [--wait] -- PROGRAM [ARG]... | wait ID [--timeout-sec N] | status [ID] | logs ID | cancel ID | export ID [--credential FILE] | destroy ID [--discard] | reconcile | record-exit ID'
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

# 29: an instance id doubles as the Herdr runtime id (rt-<id>, Herdr agent names <= 32)
valid_id() { [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,27}[a-z0-9])?$ && $1 != exports ]]; }
take_id() {
  [ $# -ge 1 ] || usage
  valid_id "$1" || fail usage "instance id must be a DNS label of at most 29 characters, not \`exports\`: $1"
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
  printf 'passwd: files\ngroup: files\nhosts: files\n' >"$root/etc/nsswitch.conf"
  touch "$root/etc/agent-runtime/template.json"
  touch "$root/etc/agent-runtime/execution-request.json"
  ln -sfn "$sh" "$root/bin/sh"
  ln -sfn "$(realpath "$(command -v env)")" "$root/usr/bin/env"
}
unit_active() {  # INVOCATION: the instance's unit is that invocation and not yet inactive
  local cur active
  cur=$(systemctl show -p InvocationID --value "$unit" 2>/dev/null || true)
  active=$(systemctl show -p ActiveState --value "$unit" 2>/dev/null || true)
  [ -n "$1" ] && [ "$cur" = "$1" ] && [[ $active =~ ^(active|activating|deactivating|reloading)$ ]]
}
unit_live() {  # the unit is up by name (the invocation isn't recorded yet during start)
  local active
  active=$(systemctl show -p ActiveState --value "$unit" 2>/dev/null || true)
  [[ $active =~ ^(active|activating|deactivating|reloading)$ ]]
}
lock_held() {  # a start (or another op) holds the instance lock right now; a non-blocking probe, lock untouched
  ! ( flock -n 7 ) 7>"$base/.lock" 2>/dev/null
}
invocation_of() {  # the run's journal key: started.json's, else the one record-exit saw
  local inv
  inv=$(jq -r '.invocation // empty' "$base/started.json" 2>/dev/null || true)
  [ -n "$inv" ] || inv=$(jq -r '.invocation // empty' "$base/result.json" 2>/dev/null || true)
  printf '%s' "$inv"
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
      # the unit is gone with no result yet: its ExecStopPost (record-exit) may still be writing one.
      # Wait briefly; only an outcome that never lands (supervisor or host crash) is ambiguous.
      for _ in $(seq 1 30); do
        [ -f "$base/result.json" ] && { jq -r .outcome "$base/result.json"; return; }
        unit_active "$(jq -r .invocation "$base/started.json")" && { echo running; return; }
        sleep 0.1
      done
      echo ambiguous
    fi
  elif [ -e "$base/starting" ]; then
    # the up-to-5 s start window (lock held) or a unit up by name is not final: a concurrent wait
    # must not fail a run that then succeeds. Only a vanished unit with nothing recorded is ambiguous.
    if lock_held || unit_live; then echo starting; else echo ambiguous; fi
  else
    echo created
  fi
}
terminal() { [[ $1 =~ ^(succeeded|failed|timed-out|oom-killed|cancelled|ambiguous)$ ]]; }
# write_mirror STATE [OUTCOME] [REASON] (#169): the world-readable (0644) lifecycle mirror a Herdr
# status follower reads so the direct run shows in Herdr with no new privilege. A different file from
# the credential ($rundir/$id/cred/token, 0400), written only at launch ("starting") and at the
# recorded outcome, so the two writers never clobber. It carries ONLY non-secret lifecycle state.
write_mirror() {
  local m=$rundir/$id/mirror.status
  mkdir -p "$rundir/$id"
  jq -nc --arg s "$1" --arg o "${2:-}" --arg r "${3:-}" \
    '{state: $s, outcome: (($o | select(. != "")) // null), reason: (($r | select(. != "")) // null)}' >"$m.tmp"
  chmod 0644 "$m.tmp"
  mv "$m.tmp" "$m"
}
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
revoke_token() {  # ISSUER TOKEN-FILE: best effort (the token expires anyway), but a failure is reported, not hidden
  local rc=0 detail
  detail=$(timeout 30 "$1" revoke --instance "$id" --token-file "$2" 2>&1 >/dev/null) || rc=$?
  [ "$rc" -ne 0 ] || return 0
  detail=$(redact_stream "$(cat "$2" 2>/dev/null || true)" <<<"$detail" | tr '\n' ' ' | tail -c 300)
  jq -nc --arg m "$id: revoking the minted token at the issuer failed (exit $rc); it stays valid until it expires: $detail" \
    '{warning: {class: "credential", message: $m}}' >&2
}
teardown() {  # every step idempotent; a step that fails leaves the reservation, so the instance stays counted
  local name
  systemctl stop "$unit" 2>/dev/null || true
  systemctl reset-failed "$unit" 2>/dev/null || true
  # the egress allowlist table, if any (the veth dies with the container's netns on stop)
  command -v nft >/dev/null && nft delete table inet "art_$id" 2>/dev/null || true
  # a minted token is revoked at the issuer before its tmpfs copy goes
  if [ -f "$base/cred-issuer" ] && [ -f "$rundir/$id/cred/token" ]; then
    revoke_token "$(cat "$base/cred-issuer")" "$rundir/$id/cred/token"
  fi
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
    template='' host=/etc/agent-runtime/host.json task='' plans=()
    while [ $# -gt 0 ]; do
      case $1 in
        --template) [ $# -ge 2 ] || usage; template=$2; shift 2 ;;
        --host) [ $# -ge 2 ] || usage; host=$2; shift 2 ;;
        --task) [ $# -ge 2 ] || usage; task=$2; shift 2 ;;
        --plan) [ $# -ge 2 ] || usage; plans+=(--plan "$2"); shift 2 ;;
        *) usage ;;
      esac
    done
    [ -n "$template" ] && [ -n "$task" ] || usage
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
    # egress "none" or "allowlist" (#137 slice 2); capabilities declare intent, the per-run credential is a
    # separate grant delivered at start (never from the manifest). Minting a real scoped token stays open.
    jq -e '.policies.network.egress as $e | $e == "none" or $e == "allowlist"' "$template" >/dev/null \
      || fail unsupported "$name: network egress must be none or allowlist"
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
    # the sum above covers admitted-but-not-started instances; MemAvailable covers what other host
    # workloads use now, for this instance only. Both must hold.
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
    # the manifest references the template's whole closure (packages, skills): rooted here, an
    # in-flight instance keeps it across a template profile update and nix-collect-garbage -d
    template_store=$(realpath "$template")
    if [[ $template_store == /nix/store/* ]]; then
      run_capture store "cannot root the template $template_store" nix_cmd build --out-link "$base/template-root" "$template_store"
    fi
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
      --slurpfile t "$template" --slurpfile r "$base/run/run.json" --arg ts "$template_store" '
      {schemaVersion: 1, kind: "agent-runtime-instance-record", id: $id, task: $task, host: $host,
       template: {name: $t[0].template.name, digests: $t[0].digests, manifest: $ts}, run: {digest: $r[0].digests.run},
       uidBase: $uid, unit: $unit, machine: $machine, createdAt: $at,
       volumes: ($vols | with_entries(.value |= {path, sizeMiB, inodes} + {image: ($b + "/img/" + .key + ".img"), mount: ($b + "/vol/" + .key)}))}' \
      | atomic_json "$base/instance.json"
    trap - EXIT
    status_json
    ;;

  start)
    take_id "$@"
    shift
    uid=1000 timeout_sec='' opt='' wait=0 cred_file='' issuer='' cred_ttl='' request_file=''
    while [ $# -gt 0 ]; do
      case $1 in
        --request) [ $# -ge 2 ] || usage; request_file=$2; shift 2 ;;
        --root) uid=0; shift ;;
        --timeout-sec) [ $# -ge 2 ] || usage; timeout_sec=$2; shift 2 ;;
        --idmap) opt=:idmap; shift ;;
        --wait) wait=1; shift ;;
        # a per-run secret read from a host path (LoadCredential, a sops path); delivered on tmpfs,
        # never written under the instance's persistent /var/lib state, never from the manifest
        --credential) [ $# -ge 2 ] || usage; cred_file=$2; shift 2 ;;
        # or a token minted for this run by a host-side issuer, scoped to the template's capabilities, with an expiry
        --credential-issuer) [ $# -ge 2 ] || usage; issuer=$2; shift 2 ;;
        --credential-ttl) [ $# -ge 2 ] || usage; cred_ttl=$2; shift 2 ;;
        --) shift; break ;;
        *) usage ;;
      esac
    done
    [ -z "$cred_file" ] || [ -f "$cred_file" ] || fail usage "--credential $cred_file not found"
    [ -z "$cred_file" ] || [ -z "$issuer" ] || fail usage "--credential and --credential-issuer exclude each other"
    [ -z "$issuer" ] || [ -x "$issuer" ] || fail usage "--credential-issuer $issuer is not executable"
    if [ -n "$request_file" ]; then
      [ -f "$request_file" ] && [ ! -L "$request_file" ] || fail usage "--request must be a regular non-symlink JSON file"
      request_file=$(realpath -e -- "$request_file") || fail usage "--request file does not resolve"
    fi
    # absolute (not symlink-resolved): teardown runs it from whatever directory destroy is called in
    [ -z "$issuer" ] || issuer=$(realpath -s -- "$issuer")
    [ -n "$issuer" ] || [ -z "$cred_ttl" ] || fail usage "--credential-ttl needs --credential-issuer"
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
    request_sha=''
    if [ -n "$request_file" ]; then
      request_target=$rundir/$id/execution-request.json
      request_tmp=$request_target.tmp.$$
      mkdir -p "$rundir/$id"
      install -m 0400 -- "$request_file" "$request_tmp"
      if ! jq -e --slurpfile run "$base/run/run.json" '
        def argv: type == "array" and length > 0 and length <= 128
          and all(.[]; type == "string" and length > 0 and length <= 4096 and (test("[\\x00-\\x1f\\x7f]") | not));
        . as $request
        | .schema_version == 1
          and .kind == "devenv-platform/execution-request"
          and .status == "ready" and .blockers == []
          and (.source.repo | type == "string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))
          and .source.url == ("https://github.com/" + .source.repo)
          and (.source.ref | type == "string" and length > 0 and length <= 255)
          and (.source.sha | type == "string" and test("^[0-9a-f]{40}$"))
          and (.source.root | type == "string" and length > 0 and length <= 1024
            and (. == "." or ((test("[\\x00-\\x1f\\x7f\\\\]") | not)
              and (startswith("/") | not)
              and (split("/") | all(. != "" and . != "." and . != "..")))))
          and .environment.kind == "devenv"
          and (.environment.index | type == "number" and . >= 0 and floor == .)
          and .environment.root == .source.root and .environment.shell == "devenv"
          and (.target_system | type == "string" and test("^[a-z0-9_]+-[a-z0-9_]+$"))
          and (.provenance.plan_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
          and (.provenance.lockfiles | type == "array" and length > 0
            and all(.[]; (.path | type == "string" and length > 0 and (test("[\\x00-\\x1f\\x7f\\\\]") | not)
              and (split("/") | all(. != "" and . != "." and . != "..")))
              and (.blob | type == "string" and test("^[0-9a-f]{40}$"))))
          and (.check.argv | argv)
          and ([$run[0].sources[] | select((.github | ascii_downcase) == ($request.source.repo | ascii_downcase)
            and .resolved.rev == $request.source.sha)] | length == 1)
          and ([$run[0].sources[] | select((.github | ascii_downcase) == ($request.source.repo | ascii_downcase)
            and .resolved.rev == $request.source.sha)
            | select(.resolved.by != "plan" or
              (.resolved.plan == $request.provenance.plan_sha256 and .ref.value == $request.source.ref))] | length == 1)
      ' "$request_tmp" >/dev/null; then
        rm -f -- "$request_tmp"
        fail plan "$id: request must be ready, supported, and match the assigned repository commit and plan"
      fi
      mv -f -- "$request_tmp" "$request_target"
      chmod 0444 "$request_target"
      request_sha=$(sha256sum "$request_target" | cut -d' ' -f1)
    fi
    uidbase=$(awk '{print $3}' "$base/reservation")
    mount_volumes
    build_root
    path=$(jq -r '[.packages[].storePath + "/bin"] | join(":")' "$t")
    binds=(--bind-ro="/nix/store:/nix/store$opt" --bind-ro="$base/template.json:/etc/agent-runtime/template.json")
    request_env=()
    if [ -n "$request_sha" ]; then
      binds+=(--bind-ro="$request_target:/etc/agent-runtime/execution-request.json")
      request_env+=(--setenv=AGENT_RUNTIME_EXECUTION_REQUEST=/etc/agent-runtime/execution-request.json)
    fi
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
    # egress (#137 slice 2): an allowlist template gets a veth the host filters after the unit starts;
    # the payload waits for the host's go. A per-run credential is delivered on tmpfs, never /var/lib.
    egress=$(jq -r .policies.network.egress "$t")
    netflag=(--private-network) netready='' allow_ips='' netbind=()
    if [ "$egress" = allowlist ]; then
      netflag=(--private-network --network-veth)
      netready="$(jq -r .filesystem.tmp.path "$t")/.net-ready"
      # Resolve the allowlist and pin it as the container's /etc/hosts via a read-only bind: nspawn rewrites
      # a container's rootfs /etc/hosts at boot, so the names must arrive as a bind mount it will not touch.
      # Port 53 is never opened, so the pinned names are the only resolvable egress targets.
      # off-host egress is forwarded and masqueraded (below): without IPv4 forwarding nothing leaves (#169)
      [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = 1 ] \
        || fail state "$id: allowlist egress needs IPv4 forwarding on the host (net.ipv4.ip_forward=1); nothing was started"
      hostsfile=$rundir/$id/hosts
      printf '127.0.0.1 localhost\n' >"$hostsfile"
      while IFS= read -r n; do
        [ -n "$n" ] || continue
        # IPv4 only: the filter matches `ip daddr`; an IPv6 answer would only make it fail to install
        aip=$(getent ahostsv4 "$n" | awk '{print $1; exit}') || true
        [ -n "$aip" ] || fail state "$id: egress allowlist name $n did not resolve on the host"
        printf '%s %s\n' "$aip" "$n" >>"$hostsfile"
        allow_ips="$allow_ips $aip"
      done < <(jq -r '.policies.network.allow[]?' "$t")
      netbind=(--bind-ro="$hostsfile:/etc/hosts")
    fi
    # the credential: a token the issuer mints for this run, or a host file; either way only on tmpfs, never in a record
    credbind=() cred_meta=null minted=''
    # a start that died after minting but before its marker leaves state `created` with the minted token and
    # its issuer record: revoke that token and drop both, so this start's credential is never sent to revoke
    if [ -f "$base/cred-issuer" ]; then
      if [ -f "$rundir/$id/cred/token" ]; then revoke_token "$(cat "$base/cred-issuer")" "$rundir/$id/cred/token"; fi
      rm -f "$base/cred-issuer" "$rundir/$id/cred/token"
    fi
    if [ -n "$issuer" ]; then
      caps=$(jq -c '.policies.capabilities' "$t")
      [ "$(jq length <<<"$caps")" -gt 0 ] || fail credential "$id: the template declares no capabilities; there is nothing to mint"
      ttl=${cred_ttl:-$limit}
      [[ $ttl =~ ^[1-9][0-9]*$ ]] && [ "$ttl" -le "$limit" ] || fail usage "--credential-ttl must be 1..$limit seconds: a token never outlives the run"
      run_capture credential "the credential issuer failed" \
        "$issuer" mint --instance "$id" --task "$(jq -r .task "$base/instance.json")" --capabilities "$caps" --ttl "$ttl"
      minted=$captured
      jq -e --argjson caps "$caps" --argjson now "$(date +%s)" --argjson ttl "$ttl" '
        (.token | type == "string" and test("^[A-Za-z0-9._~+/=-]{16,4096}$"))
        and (.scopes | type == "array" and length > 0 and all(.[]; . as $s | $caps | index($s)))
        and (.expires_at | type == "number" and . > $now and . <= $now + $ttl + 5)' <<<"$minted" >/dev/null || {
        # a refused token is still live at the issuer: revoke it, when there is one to name
        refused=$rundir/$id/refused-token
        if (umask 077; mkdir -p "$rundir/$id"; jq -ej '.token | strings' <<<"$minted" >"$refused") 2>/dev/null; then
          revoke_token "$issuer" "$refused"
        fi
        rm -f "$refused"
        fail credential "$id: the issuer's token is malformed, not within the template's capabilities $caps, or not expiring within ${ttl}s; nothing was started"
      }
      cred_meta=$(jq -c --arg i "$issuer" '{kind: "minted", issuer: $i, scopes, expiresAt: .expires_at}' <<<"$minted")
      printf '%s\n' "$issuer" | atomic_json "$base/cred-issuer"
    elif [ -n "$cred_file" ]; then
      cred_meta='{"kind":"file","scopes":null,"expiresAt":null}'
    fi
    if [ -n "$minted" ] || [ -n "$cred_file" ]; then
      creddir=$rundir/$id/cred
      mkdir -p "$creddir"
      chmod 0700 "$creddir"
      if [ -n "$minted" ]; then (umask 077; jq -j .token <<<"$minted" >"$creddir/token"); else install -m 0400 "$cred_file" "$creddir/token"; fi
      chmod 0400 "$creddir/token"
      chown -R "$((uidbase + uid)):$((uidbase + uid))" "$creddir"
      credbind=(--bind-ro="$creddir:/run/agent-runtime/credentials")
    fi
    setpriv=$(realpath "$(command -v setpriv)")
    exec_tail=("$setpriv" --reuid="$uid" --regid="$uid" --clear-groups --bounding-set=-all --inh-caps=-all --no-new-privs --)
    if [ -n "$netready" ]; then
      # shellcheck disable=SC2016  # $0/$@ expand inside the container shell, not here
      exec_tail+=(/bin/sh -c 'while [ ! -e "$0" ]; do sleep 0.1; done; exec "$@"' "$netready" "$@")
    else
      exec_tail+=("$@")
    fi
    # not --quiet: systemd-run reports the invocation id itself, so a payload that exits before
    # `systemctl show` asks (and --collect drops the unit) still has its journal key (#138)
    args=(systemd-run --unit="$unit" --collect --service-type=exec
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
        "${netflag[@]}" --as-pid2 --resolv-conf=off --timezone=off --no-new-privileges=yes
        --drop-capability="$drop"
        "${binds[@]}" "${credbind[@]}" "${netbind[@]}"
        --setenv=PATH="$path" --setenv=HOME="$(jq -r .filesystem.home.path "$t")"
        "${request_env[@]}"
        --setenv=TMPDIR="$(jq -r .filesystem.tmp.path "$t")" --setenv=AGENT_RUNTIME_INSTANCE="$id"
        --setenv=AGENT_RUNTIME_OUTPUT="$(jq -r .filesystem.output.path "$t")"
        -- "${exec_tail[@]}")
    printf -v command '%q ' "$@"
    # the marker comes first: a crash between it and the unit is reported as ambiguous, never re-run
    jq -nc --arg at "$(now)" '{at: $at}' | atomic_json "$base/starting"
    # the Herdr status mirror (#169): "starting" now, the outcome at record-exit; maps to `working`
    write_mirror starting
    systemctl reset-failed "$unit" 2>/dev/null || true
    run_capture state "systemd-run failed" "${args[@]}"
    invocation=$(sed -n 's/.*invocation ID: \([0-9a-f]\{32\}\).*/\1/p' <<<"$captured_err")
    [ -n "$invocation" ] || invocation=$(systemctl show -p InvocationID --value "$unit" 2>/dev/null || true)
    leader=''
    for _ in $(seq 1 50); do
      leader=$(machinectl show -p Leader --value "$machine" 2>/dev/null || true)
      [ -z "$leader" ] || break
      sleep 0.1
    done
    # egress: configure the instance's veth and pin the allowlist filter on the host before the payload's
    # net-ready. Filtered on BOTH input (host-local endpoints/resolver) and forward (routed off the host);
    # names are already pinned into /etc/hosts and port 53 is never opened, so there is no name-based path.
    if [ "$egress" = allowlist ] && [ -n "$leader" ]; then
      slot=$(( (uidbase - 1048576) / 65536 ))
      sub="10.$((slot / 256)).$((slot % 256))"
      # the instance's own end names its peer (host0@ifN, N the host-side index): two egress starts at once
      # cannot take each other's veth, as a before/after diff of the host's links could
      veth=''
      for _ in $(seq 1 50); do
        peer=$(nsenter -t "$leader" -n ip -o link show host0 2>/dev/null | sed -n 's/^[0-9]*: host0@if\([0-9]*\):.*/\1/p')
        if [ -n "$peer" ]; then
          veth=$(ip -o link show | awk -F': ' -v i="$peer" '$1 == i {print $2; exit}' | cut -d@ -f1)
        fi
        if [ -n "$veth" ]; then break; fi
        sleep 0.1
      done
      [ -n "$veth" ] || fail state "$id: the egress veth never appeared"
      ip addr add "$sub.1/24" dev "$veth"; ip link set "$veth" up
      nsenter -t "$leader" -n ip addr add "$sub.2/24" dev host0
      nsenter -t "$leader" -n ip link set host0 up
      nsenter -t "$leader" -n ip link set lo up
      nsenter -t "$leader" -n ip route add default via "$sub.1"
      tbl="art_$id"
      nft add table inet "$tbl"
      for hook in input forward; do
        nft add chain inet "$tbl" "$hook" "{ type filter hook $hook priority -10; policy accept; }"
        nft add rule inet "$tbl" "$hook" iifname "$veth" ct state established,related accept
        for aip in $allow_ips; do nft add rule inet "$tbl" "$hook" iifname "$veth" ip daddr "$aip" tcp dport 443 accept; done
        nft add rule inet "$tbl" "$hook" iifname "$veth" drop
      done
      # source NAT for what the filter forwards off the host (#169): the instance's 10.x source is private,
      # so without it a reply to an off-host endpoint never comes back and the connect hangs. In the same
      # table, so teardown's `nft delete table` removes it with the filter
      nft add chain inet "$tbl" postrouting "{ type nat hook postrouting priority srcnat; policy accept; }"
      nft add rule inet "$tbl" postrouting ip saddr "$sub.0/24" oifname != "$veth" masquerade
      touch "$base/vol/tmp/.net-ready"
    fi
    ns='{}' uid_map=null
    if [ -n "$leader" ]; then
      for n in user mnt pid ipc uts net cgroup time; do
        ns=$(jq -c --arg n "$n" --arg v "$(readlink "/proc/$leader/ns/$n" 2>/dev/null || true)" '.[$n] = $v' <<<"$ns")
      done
      uid_map=$(jq -Rc 'split(" ") | map(select(length > 0) | tonumber)' <"/proc/$leader/uid_map" 2>/dev/null || echo null)
    fi
    jq -nc --arg at "$(jq -r .at "$base/starting")" --arg inv "$invocation" --argjson uid "$uid" --argjson timeout "$limit" \
      --arg request_sha "$request_sha" \
      --arg command "${command% }" --arg cg "$(systemctl show -p ControlGroup --value "$unit" 2>/dev/null || true)" \
      --arg leader "$leader" --argjson ns "$ns" --argjson map "$uid_map" --arg store "${opt:-plain}" --argjson cm "$cred_meta" \
      '{startedAt: $at, invocation: $inv, uid: $uid, timeoutSec: $timeout, command: $command, controlGroup: $cg,
        requestSha256: (if $request_sha == "" then null else $request_sha end),
        leaderPid: ($leader | if . == "" then null else tonumber end), namespaces: $ns, uidMap: $map, storeBind: $store,
        credential: $cm}' \
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
    # a cancel wins even over an exit 0: a payload that traps SIGTERM and exits 0 was still stopped, and
    # one that finished in the instant before the cancel reads cancelled too; exitStatus keeps the truth
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
    # the Herdr status mirror (#169): the recorded outcome and its non-secret reason, never the token
    reason=$service_result
    [ -z "$exit_status" ] || reason="$service_result (exit $exit_status)"
    write_mirror "$outcome" "$outcome" "$reason"
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
    [ -f "$base/started.json" ] || fail state "$id has not been started"
    inv=$(invocation_of)
    [ -n "$inv" ] || fail state "$id has no recorded invocation"
    journalctl --sync 2>/dev/null || true
    cred=$(cat "$rundir/$id/cred/token" 2>/dev/null || true)
    if [ -n "$cred" ]; then
      journalctl -o cat --no-pager "_SYSTEMD_INVOCATION_ID=$inv" | tail -c "$log_cap" | redact_stream "$cred"
    else
      journalctl -o cat --no-pager "_SYSTEMD_INVOCATION_ID=$inv" | tail -c "$log_cap"
    fi
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
    shift
    recheck=''
    if [ "${1:-}" = --credential ]; then [ $# -ge 2 ] && [ -r "$2" ] || usage; recheck=$2; shift 2; fi
    [ -d "$base" ] || fail state "$id does not exist"
    lock_instance
    s=$(state_of)
    if [ -f "$base/exported.json" ]; then status_json; exit 0; fi
    terminal "$s" || fail conflict "$id is $s; export after it has ended"
    mount_volumes
    out=$state/exports/$id
    [ ! -e "$out" ] || fail conflict "$out exists but $id has no export record"
    mkdir -p "$state/exports"
    # a run that had a credential whose copy is gone (a reboot) is not exported unchecked: re-pass it
    cred=$(cat "$rundir/$id/cred/token" 2>/dev/null || true)
    [ -n "$cred" ] || [ -z "$recheck" ] || cred=$(<"$recheck")
    if [ -z "$cred" ] && jq -e '.credential != null' "$base/started.json" >/dev/null 2>&1; then
      fail credential "$id ran with a credential whose copy is gone, so the export cannot be checked for it; re-pass it: export $id --credential FILE"
    fi
    tmp=$(mktemp -d "$state/exports/.$id.XXXXXX")
    ws=$base/vol/workspace
    # a failed export after the source export ran puts the sources back as pending, so a retry exports (and
    # scans) the patch again instead of leaving it out
    restore_pending() {
      if [ -f "$tmp/.export-pending" ] && [ ! -e "$ws/export-pending" ]; then
        cp "$tmp/.export-pending" "$ws/export-pending" && rm -f "$ws/exported.json"
      fi
      rm -rf "$tmp"
    }
    trap restore_pending EXIT
    if [ -f "$ws/export-pending" ]; then
      cp "$ws/export-pending" "$tmp/.export-pending"
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
    inv=$(invocation_of)
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
    # the credential leak gate (#137, #169): the diagnostic log is redacted in place; an output file or a source
    # patch that carries the run's secret refuses the export
    if [ -n "$cred" ]; then
      [ -f "$tmp/run.log" ] && redact_file "$cred" "$tmp/run.log"
      ! grep -rqF -- "$cred" "$tmp/output" "$tmp/sources" 2>/dev/null \
        || fail credential "$id: the run credential appears in an exported artifact (an output file or a source patch)"
    fi
    # past every refusal: the backup is not part of the bundle
    rm -f "$tmp/.export-pending"
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
