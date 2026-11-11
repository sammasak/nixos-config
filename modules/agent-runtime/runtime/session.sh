# shellcheck shell=bash
# agent-runtime-session: the session user's side of an interactive instance (docs/agent-runtime-session.md).
# `attach` needs no root: the client connects to the dtach socket `start` left in the instance's session
# directory, which the host's session.attachUser may traverse. `run` and `end` go through the one root
# helper (`@launch@`, by sudo rule). `@clients@` holds the dtach client under each pane process name.
# `run` leaves a watcher behind (a user unit) that ends the session when its program does and runs the
# host's lifecycle hooks, so nothing depends on the terminal staying open.
USAGE='agent-runtime-session run [--template NAME] [--task OWNER/REPO#N] [ID] | attach ID | end ID | list'
usage() { echo "usage: $USAGE" >&2; exit 2; }
die() { echo "agent-runtime-session: $1" >&2; exit 1; }
clients="@clients@"
launch=("@launch@")
[ "$(id -u)" = 0 ] || launch=(/run/wrappers/bin/sudo -n "${launch[0]}")
host_policy=/etc/agent-runtime/host.json
manifests=/nix/var/nix/profiles/agent-runtime/templates/templates
rundir=/run/agent-runtime
valid_id() { [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,27}[a-z0-9])?$ && $1 != exports ]]; }
state_of() { jq -r '.state // "unknown"' "$rundir/$1/mirror.status" 2>/dev/null || echo absent; }
# the client for ID: named as the template asks (a name outside the built set falls back to dtach)
client_of() {
  local name
  name=$(jq -r '.paneProcessName // "dtach"' "$rundir/$1/session.json" 2>/dev/null || echo dtach)
  if ! [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && -x $clients/$name ]]; then name=dtach; fi
  printf '%s' "$clients/$name"
}
sock_of() {
  local sock=$rundir/$1/session/pty.sock
  [ -S "$sock" ] || die "$1 is not a running session this user may attach to (state: $(state_of "$1"))"
  printf '%s' "$sock"
}

note() { echo "agent-runtime-session: $1" >&2; logger -t agent-runtime-session -- "$1" 2>/dev/null || true; }
# hooks EVENT: the host's commands for it, each bounded; a failure is logged and nothing else
hooks() {
  local cmd rc limit
  limit=$(jq -r '.session.hookTimeoutSec // 20' "$host_policy" 2>/dev/null || echo 20)
  export AGENT_RUNTIME_SESSION_EVENT=$1
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    rc=0
    timeout -k 2 "$limit" /bin/sh -c "$cmd" </dev/null >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] || note "$AGENT_RUNTIME_SESSION_ID: $1 hook \`$cmd\` exited $rc (ignored)"
  done < <(jq -r --arg e "$1" '.session.hooks[$e][]?' "$host_policy" 2>/dev/null || true)
}
# The watcher outlives the terminal: a user unit carrying what `herdr` needs to reach this user's
# server; with no user manager, a detached process instead.
spawn_watch() {  # ID TEMPLATE TASK started|running
  local self unit=agent-runtime-session-watch-$1 v env scope=(--user)
  self=$(realpath "$0")
  env=(--setenv=PATH="$PATH" --setenv=HOME="${HOME:-/}")
  for v in $(env | sed -n 's/^\(HERDR_[A-Za-z0-9_]*\)=.*/\1/p') XDG_RUNTIME_DIR; do
    [ -z "${!v:-}" ] || env+=(--setenv="$v=${!v}")
  done
  [ "$(id -u)" != 0 ] || scope=()
  if systemd-run "${scope[@]}" --quiet --collect --unit="$unit" "${env[@]}" "$self" _watch "$@" 2>/dev/null; then return 0; fi
  if systemctl "${scope[@]}" is-active --quiet "$unit.service" 2>/dev/null; then return 0; fi
  setsid -f "$self" _watch "$@" </dev/null >/dev/null 2>&1 || note "$1: no watcher; end it with: agent-runtime-session end $1"
}

[ $# -ge 1 ] || usage
cmd=$1
shift
case $cmd in
  attach)  # detach with Ctrl-\; the session keeps running
    if [ $# -ne 1 ] || ! valid_id "$1"; then usage; fi
    sock=$(sock_of "$1")
    exec "$(client_of "$1")" -a "$sock" -r winch -z
    ;;

  run)
    template='' task='' id=''
    while [ $# -gt 0 ]; do
      case $1 in
        --template) [ $# -ge 2 ] || usage; template=$2; shift 2 ;;
        --task) [ $# -ge 2 ] || usage; task=$2; shift 2 ;;
        -*) usage ;;
        *) [ -z "$id" ] || usage; id=$1; shift ;;
      esac
    done
    [ -n "$id" ] || id=s-$(date +%m%d-%H%M%S)
    valid_id "$id" || usage
    [ -n "$task" ] || task=$(jq -r '.session.defaultTask // empty' "$host_policy" 2>/dev/null || true)
    [ -n "$task" ] || die "no --task OWNER/REPO#N, and the host sets no session.defaultTask"
    if [ -z "$template" ]; then
      found=()
      while IFS= read -r n; do
        if jq -e '.session != null' "$manifests/$n.json" >/dev/null 2>&1; then found+=("$n"); fi
      done < <(jq -r '.eligibleTemplates[]' "$host_policy" 2>/dev/null || true)
      [ "${#found[@]}" -eq 1 ] || die "the host has ${#found[@]} eligible session templates (${found[*]}); name one with --template"
      template=${found[0]}
    fi
    how=$("${launch[@]}" start "$id" "$template" "$task") || die "the session was not started"
    spawn_watch "$id" "$template" "$task" "$how"
    sock=$(sock_of "$id")
    # not exec: the outcome is reported below. Job control gives the client its own foreground process
    # group, so the terminal's foreground process is the client under its pane name, not this shell.
    set -m
    "$(client_of "$id")" -a "$sock" -r winch -z || true
    set +m
    if [ -S "$sock" ]; then
      printf '\nsession %s is still running (detached). rejoin: agent-runtime-session attach %s; stop: agent-runtime-session end %s\n' "$id" "$id" "$id"
      exit 0
    fi
    # the watcher exports and destroys once the payload has ended; wait for it, then name the bundle
    for _ in $(seq 1 240); do
      [ -e "$rundir/$id" ] || break
      sleep 0.5
    done
    if [ -e "$rundir/$id" ]; then
      die "session $id ended ($(state_of "$id")) but is not cleaned up yet; run: agent-runtime-session end $id"
    fi
    printf '\nsession %s ended; bundle: /var/lib/agent-runtime/exports/%s.runs/latest\n' "$id" "$id"
    ;;

  end)
    if [ $# -ne 1 ] || ! valid_id "$1"; then usage; fi
    out=$("${launch[@]}" end "$1") || die "$1 was not ended"
    jq -r '"\(.outcome)\t\(.bundle // "no bundle")"' <<<"$out"
    ;;

  _watch)  # ID TEMPLATE TASK started|running: internal, the unit `run` leaves behind
    if [ $# -ne 4 ] || ! valid_id "$1"; then usage; fi
    id=$1
    # one watcher per session: a second `run` of the same id only rejoins
    exec 8>"${XDG_RUNTIME_DIR:-${HOME:-/tmp}}/.agent-runtime-session-watch-$id.lock"
    flock -n 8 || exit 0
    export AGENT_RUNTIME_SESSION_ID=$id AGENT_RUNTIME_SESSION_TEMPLATE=$2 AGENT_RUNTIME_SESSION_TASK=$3
    export AGENT_RUNTIME_SESSION_OUTCOME='' AGENT_RUNTIME_SESSION_BUNDLE='' AGENT_RUNTIME_SESSION_ERROR=''
    AGENT_RUNTIME_SESSION_HOST=$(</proc/sys/kernel/hostname)
    export AGENT_RUNTIME_SESSION_HOST
    if [ "$4" = started ] && [ -S "$rundir/$id/session/pty.sock" ]; then hooks start; fi
    last=unknown
    while [ -e "$rundir/$id" ]; do
      last=$(state_of "$id")
      [[ $last =~ ^(succeeded|failed|timed-out|oom-killed|cancelled|ambiguous)$ ]] && break
      sleep 1
    done
    if out=$("${launch[@]}" end "$id" 2>/dev/null); then
      AGENT_RUNTIME_SESSION_OUTCOME=$(jq -r '.outcome' <<<"$out")
      AGENT_RUNTIME_SESSION_BUNDLE=$(jq -r '.bundle // ""' <<<"$out")
    else
      AGENT_RUNTIME_SESSION_OUTCOME=$last
      AGENT_RUNTIME_SESSION_ERROR="export or destroy failed; see journalctl -t agent-runtime-session-launch, then: agent-runtime-session end $id"
      note "$id: $AGENT_RUNTIME_SESSION_ERROR"
    fi
    hooks end
    rm -f "${XDG_RUNTIME_DIR:-${HOME:-/tmp}}/.agent-runtime-session-watch-$id.lock"
    ;;

  list)
    [ $# -eq 0 ] || usage
    for f in "$rundir"/*/session.json; do
      [ -r "$f" ] || continue
      d=$(dirname "$f")
      jq -c --arg s "$(state_of "$(basename "$d")")" --argjson up "$([ -S "$d/session/pty.sock" ] && echo true || echo false)" \
        '{id, template, task, state: $s, attachable: $up}' "$f"
    done
    ;;

  *) usage ;;
esac
