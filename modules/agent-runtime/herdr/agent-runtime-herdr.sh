# shellcheck shell=bash
# agent-runtime-herdr: the host-side adapter that makes an ephemeral agent
# runtime a Herdr agent on the physical host (#139). The runtime's agent runs in
# a pane of the host's Herdr server; the container never talks to Herdr. Its
# identity, title and lifecycle state come from here, through the stock Herdr
# CLI, and a registry under $AGENT_RUNTIME_HERDR_STATE keeps the local truth
# when Herdr is unreachable.
#
#   attach <runtime_id> <manifest.json> <OWNER/REPO#N> <status-file> -- <pane argv...>
#   follow <runtime_id>      (run by attach as a transient unit)
#   deliver <runtime_id> <text>   (only to an idle runtime; see below)
#   detach <runtime_id>
#   status [--json]
#   reconcile
set -euo pipefail

state_dir=${AGENT_RUNTIME_HERDR_STATE:-/var/lib/agent-runtime-herdr}
source_id=agent-runtime
# not a Herdr agent kind on purpose: a known kind (claude, codex) makes Herdr expect that
# program as the pane's foreground process and refuse prompts while nspawn holds the PTY
agent_label=agent-runtime
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
die() { echo "agent-runtime-herdr: $1" >&2; exit "${2:-1}"; }
record() { echo "$state_dir/$1.json"; }
# Herdr agent names are at most 32 characters and rt- takes three
valid_id() { [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,27}[a-z0-9])?$ ]]; }
# set <runtime_id> <jq filter> [jq args...]: update the record atomically
set_record() {
  local id=$1 filter=$2; shift 2
  local f; f=$(record "$id")
  jq --arg now "$(now)" "$@" "$filter | .updated_at = \$now" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
field() { jq -r "$2" "$(record "$1")"; }
# the agent states a runtime reports, and what Herdr is told for each
herdr_state() {
  case $1 in
    idle) echo idle ;;
    working) echo working ;;
    blocked) echo blocked ;;
    started) echo unknown ;;
    assigned) echo working ;;
    *) return 1 ;;
  esac
}

# a mirror's record status is an instance LIFECYCLE state (starting/succeeded/failed/…), not a pane
# state; map it for Herdr. Shared by `follow` and `reconcile` so a Herdr restart recovers the same
# done/blocked instead of `unknown`. cancelled/ambiguous surface as blocked so the operator sees them.
mirror_hs() {
  case $1 in
    starting|running) echo working ;;
    succeeded) echo idle ;;
    failed|oom-killed|timed-out|cancelled|interrupted|ambiguous) echo blocked ;;
    *) echo unknown ;;
  esac
}
# a blocked mirror always carries a one-line reason, even if mirror.status had none
mirror_reason() { # STATE REASON
  if [ "$1" = ambiguous ] && [ -z "$2" ]; then echo "ambiguous: decide by hand"; else echo "${2:-$1}"; fi
}
# report-agent messages are not in Herdr list/get; a native metadata token makes the concise reason observable.
report_reason() { # PANE HERDR-STATE REASON
  local pane=$1 state=$2 reason=$3
  local meta=(--clear-token blocked_reason)
  [ "$state" != blocked ] || meta=(--token "blocked_reason=$reason")
  herdr pane report-metadata "$pane" --source "$source_id" --agent "$agent_label" "${meta[@]}" >/dev/null
}
# Herdr binds a report to the foreground process; wait until the replacement has settled.
foreground() { herdr pane process-info --pane "$1" | jq -r '.result.process_info.foreground_processes[0].cmdline // empty'; }
run_pane() { # PANE ARGV...; print the settled foreground command
  local pane=$1; shift
  local previous pg='' stable=0 current
  previous=$(foreground "$pane") || return
  herdr pane run "$pane" "exec $(printf '%q ' "$@")" >/dev/null || return
  for _ in $(seq 200); do
    current=$(foreground "$pane") || return
    if [ -n "$current" ] && [ "$current" != "$previous" ] && [ "$current" = "$pg" ]; then stable=$((stable + 1)); else stable=0; fi
    pg=$current; [ "$stable" -lt 10 ] || break; sleep 0.1
  done
  [ "$stable" -ge 10 ] || die "the pane command did not settle in $pane (foreground: ${pg:-none})" 70
  printf '%s\n' "$pg"
}

user_unit=(); [ "$(id -u)" = 0 ] || user_unit=(--user)
cmd=${1:-}; shift || true
case $cmd in
  attach)
    # --mirror (#169): a status mirror whose pane starts NOTHING. The real credentialed run is the
    # direct root `start` elsewhere; this only makes it show in Herdr, the follower reading the
    # root-written world-readable mirror.status. Any other attach takes a `-- <pane argv>` as before.
    mirror=false
    if [ "${5:-}" = --mirror ]; then
      [ $# -eq 5 ] || die "usage: attach <runtime_id> <manifest.json> <OWNER/REPO#N> <status-file> --mirror" 64
      mirror=true id=$1 manifest=$2 task_ref=$3 status_file=$4; shift 5
      # a benign placeholder that only waits: it holds the pane so Herdr lists the agent, and it is
      # never `agent-runtime-pane … -- <RUN>` (which would run the instance)
      set -- "$(command -v sleep)" infinity   # absolute path: the pane need not have coreutils on PATH
    else
      [ $# -ge 5 ] && [ "$5" = -- ] || die "usage: attach <runtime_id> <manifest.json> <OWNER/REPO#N> <status-file> [--mirror | -- <pane argv...>]" 64
      id=$1 manifest=$2 task_ref=$3 status_file=$4; shift 5
    fi
    valid_id "$id" || die "runtime id must be a DNS label of at most 29 characters: $id" 64
    [[ $task_ref =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[1-9][0-9]*$ ]] || die "task_ref must be OWNER/REPO#N: $task_ref" 64
    [ "$#" -gt 0 ] || die "no pane command" 64
    template=$(jq -er .template.name "$manifest") || die "$manifest has no template name" 65
    digest=$(jq -er .digests.template "$manifest") || die "$manifest has no template digest" 65
    harness=$(jq -er .role.harness "$manifest") || die "$manifest has no harness" 65
    mkdir -p "$state_dir"
    exec 9>"$state_dir/.lock"; flock 9
    f=$(record "$id")
    # one live registration per runtime: a second attach is a duplicate, never a second pane
    if [ -e "$f" ] && ! jq -e '.status == "torn_down"' "$f" >/dev/null; then
      die "runtime $id is already registered ($(field "$id" .status)); detach it first" 73
    fi
    name="rt-$id"
    title="$task_ref rt=$id tpl=${digest:0:12}"
    if [ "$mirror" = true ]; then title="$title (mirror)"; fi
    ws=$(herdr workspace create --cwd / --label "$name" --no-focus) || die "herdr workspace create failed" 69
    workspace_id=$(jq -er .result.workspace.workspace_id <<<"$ws")
    pane_id=$(jq -er .result.root_pane.pane_id <<<"$ws")
    jq -n --arg id "$id" --arg host "$(hostname)" --arg ws "$workspace_id" --arg pane "$pane_id" --arg name "$name" \
      --arg tpl "$template" --arg dg "$digest" --arg ref "$task_ref" --arg sf "$status_file" --arg harness "$harness" --arg now "$(now)" \
      --argjson mirror "$mirror" \
      '{schemaVersion: 1, runtime_id: $id, host: $host, herdr: {workspace_id: $ws, pane_id: $pane, name: $name},
        template: $tpl, template_digest: $dg, harness: $harness, task_ref: $ref, status_file: $sf, mirror: $mirror,
        status: "started", seq: 0, deliveries: [], started_at: $now, updated_at: $now}' > "$f.tmp" && mv "$f.tmp" "$f"
    # a failed attach leaves no workspace and no live record behind, so a retry is not refused
    attached=0
    trap '[ "$attached" = 1 ] || { herdr workspace close "$workspace_id" >/dev/null 2>&1 || true; set_record "$id" ".status = \"torn_down\""; }' EXIT
    # Herdr binds a reported agent to the pane's foreground process at report time, so the
    # launcher replaces the pane's shell (exec, same pid) and the report waits until it runs
    pg=$(run_pane "$pane_id" "$@")
    herdr pane report-agent "$pane_id" --source "$source_id" --agent "$agent_label" --state unknown --seq 1 >/dev/null
    herdr agent rename "$pane_id" "$name" >/dev/null
    herdr pane report-metadata "$pane_id" --source "$source_id" --agent "$agent_label" --title "$title" >/dev/null
    set_record "$id" '.seq = 1 | .herdr.foreground = $fg' --arg fg "$pg"
    # the follow unit must reach the same Herdr server as this call: same user manager, same socket
    systemd-run "${user_unit[@]}" --unit="agent-runtime-herdr-follow-$id" --collect --quiet \
      --setenv=AGENT_RUNTIME_HERDR_STATE="$state_dir" --setenv=PATH="$PATH" --setenv=HOME="$HOME" \
      ${HERDR_SOCKET_PATH:+--setenv=HERDR_SOCKET_PATH="$HERDR_SOCKET_PATH"} \
      ${XDG_RUNTIME_DIR:+--setenv=XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR"} "$0" follow "$id"
    attached=1
    jq -c . "$f"
    ;;

  follow)
    id=$1; f=$(record "$id")
    [ -e "$f" ] || die "no record for $id" 66
    if [ "$(field "$id" .mirror)" = true ]; then
      # a status mirror (#169): the ROOT-written, world-readable JSON lifecycle file drives Herdr.
      # This follower runs as the unprivileged Herdr user and reads ONLY that file via jq — never
      # `agent-runtime-instance status` (root), never sudo, never the credential. starting/running
      # -> working; succeeded -> idle (Herdr shows it done); failed/oom-killed/timed-out -> blocked
      # with the non-secret reason; anything else or unreadable -> unknown.
      pane=$(field "$id" .herdr.pane_id); sf=$(field "$id" .status_file); last=''
      while :; do
        case $(field "$id" .status) in torn_down|lost) exit 0 ;; esac
        st=$(jq -r '.state // empty' "$sf" 2>/dev/null || true)
        if [ -n "$st" ] && [ "$st" != "$last" ]; then
          last=$st
          reason=$(jq -r '.reason // empty' "$sf" 2>/dev/null || true)
          hs=$(mirror_hs "$st")
          [ "$hs" = blocked ] && reason=$(mirror_reason "$st" "$reason")
          msg=(); [ -z "$reason" ] || msg=(--message "$reason")
          exec 9>"$state_dir/.lock"; flock 9
          seq=$(( $(field "$id" .seq) + 1 ))
          report_reason "$pane" "$hs" "$reason" || true
          herdr pane report-agent "$pane" --source "$source_id" --agent "$agent_label" --state "$hs" --seq "$seq" "${msg[@]}" >/dev/null || true
          set_record "$id" '.status = $s | .seq = ($q | tonumber)' --arg s "$st" --arg q "$seq"
          exec 9>&-
          # a terminal outcome is the last word: stop polling, leaving the agent listed at idle/blocked
          case $st in succeeded|failed|oom-killed|timed-out|cancelled|interrupted|ambiguous) exit 0 ;; esac
        fi
        sleep 0.3
      done
    fi
    # keyed on the line count, not the last line: a turn that goes working -> idle between two
    # polls still ends with idle, and must still move an assigned runtime on
    seen=0
    while :; do
      pane=$(field "$id" .herdr.pane_id); sf=$(field "$id" .status_file)
      status=$(field "$id" .status)
      case $status in finished|torn_down|lost) exit 0 ;; esac
      lines=$(wc -l < "$sf" 2>/dev/null || echo 0)
      if [ "$lines" -gt "$seen" ]; then
        seen=$lines
        now_state=$(tail -n 1 "$sf")
        if [ "$now_state" = finished ]; then
          # a finished agent is no agent: Herdr stops listing it, so nothing more can be handed to it
          herdr pane release-agent "$pane" --source "$source_id" --agent "$agent_label" >/dev/null || true
          exec 9>"$state_dir/.lock"; flock 9; set_record "$id" '.status = "finished"'; exit 0
        elif hs=$(herdr_state "$now_state"); then
          exec 9>"$state_dir/.lock"; flock 9
          seq=$(( $(field "$id" .seq) + 1 ))
          herdr pane report-agent "$pane" --source "$source_id" --agent "$agent_label" --state "$hs" --seq "$seq" >/dev/null || true
          set_record "$id" '.status = $s | .seq = ($q | tonumber)' --arg s "$now_state" --arg q "$seq"; exec 9>&-
        fi
      fi
      sleep 0.3
    done
    ;;

  deliver)
    # herdr 0.9.5's `agent prompt` accepts only a recognised agent kind in the pane's
    # foreground, which a runtime behind nspawn never is; until Herdr prompts an agent it
    # was told about (report-agent), this is the gate: idle in the registry and in Herdr
    [ $# -eq 2 ] || die "usage: deliver <runtime_id> <text>" 64
    id=$1 text=$2; f=$(record "$id")
    [ -e "$f" ] || die "no record for $id" 66
    # a status mirror starts nothing: refuse BEFORE any Herdr call (#169)
    if [ "$(field "$id" .mirror)" = true ]; then die "runtime $id is a status mirror; it starts nothing — not delivering" 75; fi
    # Enter submits: a newline inside the text would submit part of it early
    case $text in *$'\n'*|*$'\r'*) die "a handoff is one line" 64 ;; esac
    exec 9>"$state_dir/.lock"; flock 9
    status=$(field "$id" .status); pane=$(field "$id" .herdr.pane_id)
    case $status in
      idle) ;;
      blocked) die "runtime $id is blocked; not delivering" 75 ;;
      finished|torn_down|lost) die "runtime $id is $status; not delivering" 75 ;;
      *) die "runtime $id is $status, not idle; not delivering" 75 ;;
    esac
    herdr_status=$(herdr agent get "$pane" | jq -r '.result.agent.agent_status // empty') || die "herdr is unreachable; not delivering" 69
    # done is Herdr's idle-but-not-yet-seen: ready for input, as for any agent
    case $herdr_status in idle|done) ;; *) die "Herdr reports $pane as ${herdr_status:-no agent}; not delivering" 75 ;; esac
    # assigned before a byte is typed, under the same lock: the next deliver finds it not idle,
    # and a send that fails halfway leaves it assigned, never free for a second task
    seq=$(( $(field "$id" .seq) + 1 ))
    set_record "$id" '.status = "assigned" | .seq = ($q | tonumber) | .deliveries += [{at: $now, sha256: $h}]' \
      --arg q "$seq" --arg h "$(printf '%s' "$text" | sha256sum | cut -c1-64)"
    herdr pane report-agent "$pane" --source "$source_id" --agent "$agent_label" --state working --seq "$seq" >/dev/null || true
    herdr pane send-text "$pane" "$text" >/dev/null
    herdr pane send-keys "$pane" Enter >/dev/null
    echo "delivered to $id ($pane)"
    ;;

  detach)
    id=$1; f=$(record "$id")
    [ -e "$f" ] || die "no record for $id" 66
    exec 9>"$state_dir/.lock"; flock 9
    systemctl "${user_unit[@]}" stop "agent-runtime-herdr-follow-$id.service" 2>/dev/null || true
    pane=$(field "$id" .herdr.pane_id); ws=$(field "$id" .herdr.workspace_id); harness=$(field "$id" .harness)
    # Herdr may be gone (outage, restart): the local record is torn down either way
    herdr pane release-agent "$pane" --source "$source_id" --agent "$agent_label" >/dev/null 2>&1 || true
    herdr workspace close "$ws" >/dev/null 2>&1 || true
    set_record "$id" '.status = "torn_down"'
    jq -c . "$f"
    ;;

  status)
    mkdir -p "$state_dir"
    if [ "${1:-}" = --json ]; then
      find "$state_dir" -maxdepth 1 -name '*.json' -exec cat {} + | jq -sc 'sort_by(.runtime_id)'
    else
      find "$state_dir" -maxdepth 1 -name '*.json' -exec cat {} + | jq -sr 'sort_by(.runtime_id)[] | "\(.runtime_id)\t\(.status)\t\(.herdr.name)\t\(.task_ref)\t\(.template)@\(.template_digest[0:12])"'
    fi
    ;;

  reconcile)
    # after a Herdr restart or outage: a live record whose pane Herdr still lists is
    # re-reported; one whose pane is gone is lost. Nothing is ever re-assigned.
    mkdir -p "$state_dir"
    exec 9>"$state_dir/.lock"; flock 9
    herdr pane list >/dev/null 2>&1 || die "herdr is unreachable; local status: agent-runtime-herdr status" 69
    for f in "$state_dir"/*.json; do
      [ -e "$f" ] || continue
      id=$(jq -r .runtime_id "$f")
      case $(jq -r .status "$f") in torn_down|lost|finished) continue ;; esac
      pane=$(jq -r .herdr.pane_id "$f")
      # a status mirror (#169) is not driven by a pane process: its lifecycle lives in the
      # root-written mirror.status, which survives a Herdr restart. Re-read and re-map it (same
      # states as `follow`), passing the non-secret reason, so succeeded/failed come back
      # idle/blocked rather than `unknown`. If mirror.status is gone (tmpfs cleared), it is lost.
      if [ "$(jq -r '.mirror // false' "$f")" = true ]; then
        sf=$(jq -r .status_file "$f")
        st=$(jq -r '.state // empty' "$sf" 2>/dev/null || true)
        if [ -n "$st" ]; then
          info=$(herdr pane process-info --pane "$pane" 2>/dev/null) || info='{}'
          pg=$(jq -r '.result.process_info.foreground_processes[0].cmdline // empty' <<<"$info")
          if [ -z "$pg" ] || [ "$pg" != "$(jq -r '.herdr.foreground // empty' "$f")" ]; then
            # A restored shell cannot hold a custom agent: Herdr releases it on the next idle
            # shell check. Restore only the inert mirror placeholder, never a runtime or a
            # command in a foreign foreground process. pane run itself has no shell guard.
            if jq -e '.result.process_info | .shell_pid as $pid | .foreground_processes |
                length == 1 and .[0].pid == $pid and (.[0].name | IN("bash", "zsh", "fish", "sh", "dash", "ksh"))' <<<"$info" >/dev/null; then
              pg=$(run_pane "$pane" "$(command -v sleep)" infinity)
            else
              systemctl "${user_unit[@]}" stop "agent-runtime-herdr-follow-$id.service" 2>/dev/null || true
              set_record "$id" '.status = "lost"'
              echo "$id: lost (mirror pane is missing or has a foreign command; nothing re-assigned)"
              continue
            fi
          fi
          hs=$(mirror_hs "$st"); reason=$(jq -r '.reason // empty' "$sf" 2>/dev/null || true)
          [ "$hs" = blocked ] && reason=$(mirror_reason "$st" "$reason")
          msg=(); [ -z "$reason" ] || msg=(--message "$reason")
          seq=$(( $(jq -r .seq "$f") + 1 ))
          report_reason "$pane" "$hs" "$reason"
          herdr pane report-agent "$pane" --source "$source_id" --agent "$agent_label" --state "$hs" --seq "$seq" "${msg[@]}" >/dev/null
          # Names belong to the old foreground process and do not survive Herdr's restored shell.
          herdr agent rename "$pane" "$(jq -r .herdr.name "$f")" >/dev/null
          digest=$(jq -r .template_digest "$f")
          title="$(jq -r .task_ref "$f") rt=$id tpl=${digest:0:12} (mirror)"
          herdr pane report-metadata "$pane" --source "$source_id" --agent "$agent_label" --title "$title" >/dev/null
          set_record "$id" '.status = $s | .seq = ($q | tonumber) | .herdr.foreground = $fg' --arg s "$st" --arg q "$seq" --arg fg "$pg"
          echo "$id: re-reported mirror ($hs)"
        else
          systemctl "${user_unit[@]}" stop "agent-runtime-herdr-follow-$id.service" 2>/dev/null || true
          set_record "$id" '.status = "lost"'
          echo "$id: lost (mirror.status is gone; nothing to re-report)"
        fi
        continue
      fi
      # a restored pane is not a live runtime: Herdr restarts a pane with a fresh shell, so the
      # runtime is live only while its pane's foreground is still the launcher attach saw
      now_fg=$(herdr pane process-info --pane "$pane" 2>/dev/null | jq -r '.result.process_info.foreground_processes[0].cmdline // empty') || now_fg=""
      if [ -n "$now_fg" ] && [ "$now_fg" = "$(jq -r '.herdr.foreground // empty' "$f")" ]; then
        hs=$(herdr_state "$(jq -r .status "$f")") || hs=unknown
        seq=$(( $(jq -r .seq "$f") + 1 ))
        herdr pane report-agent "$pane" --source "$source_id" --agent "$agent_label" --state "$hs" --seq "$seq" >/dev/null
        set_record "$id" '.seq = ($q | tonumber)' --arg q "$seq"
        echo "$id: re-reported ($hs)"
      else
        systemctl "${user_unit[@]}" stop "agent-runtime-herdr-follow-$id.service" 2>/dev/null || true
        set_record "$id" '.status = "lost"'
        echo "$id: lost (its runtime is no longer in its pane; result and record kept, nothing re-assigned)"
      fi
    done
    ;;

  *) die "usage: agent-runtime-herdr attach|follow|deliver|detach|status|reconcile" 64 ;;
esac
