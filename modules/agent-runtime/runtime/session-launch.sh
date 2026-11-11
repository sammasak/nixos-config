# shellcheck shell=bash
# agent-runtime-session-launch: the one privileged entry point of the interactive session flow, the
# command the session user's NOPASSWD sudo rule names (docs/agent-runtime-session.md). It accepts
#   start ID TEMPLATE OWNER/REPO#N   preflight, create, start with the host's configured credential
#   end ID                           cancel if still running, export, destroy; idempotent
# and nothing else: no command, no path, no credential, no flag. The payload is the manifest's own
# entrypoint, the credential file is the host policy's, and only a session template is reachable, so
# the rule is not a way to run or destroy any other instance. `@instance@` and `@preflight@` are
# store paths substituted at build time, never PATH lookups.
instance="@instance@"
preflight="@preflight@"
host_policy=/etc/agent-runtime/host.json
manifests=/nix/var/nix/profiles/agent-runtime/templates/templates
state=/var/lib/agent-runtime
rundir=/run/agent-runtime

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
verb='' id='' tmpl='' task=''
# One structured line per decision, to the caller and to the journal; nothing in it is secret.
audit() {  # DECISION REASON
  local line
  line=$(jq -nc --arg at "$(now)" --arg verb "$verb" --arg id "$id" --arg template "$tmpl" --arg task "$task" \
    --arg decision "$1" --arg reason "$2" \
    '{kind: "agent-runtime-session-launch", at: $at, verb: $verb, id: $id, template: $template, task: $task,
      decision: $decision, reason: $reason}')
  printf '%s\n' "$line" >&2
  logger -t agent-runtime-session-launch -- "$line"
}
refuse() { audit refused "$1" || true; exit 1; }

case ${1:-} in
  start) [ $# -eq 4 ] || { audit refused "start takes exactly: ID TEMPLATE OWNER/REPO#N" || true; exit 2; } ;;
  end) [ $# -eq 2 ] || { audit refused "end takes exactly: ID" || true; exit 2; } ;;
  *) audit refused "the verb must be start or end" || true; exit 2 ;;
esac
verb=$1
# validated before it is recorded or used: the same id charset as agent-runtime-instance
[[ $2 =~ ^[a-z0-9]([a-z0-9-]{0,27}[a-z0-9])?$ ]] && [ "$2" != exports ] || refuse "the id is not a valid runtime id"
id=$2
[ -f "$host_policy" ] || refuse "host policy $host_policy is absent"

if [ "$verb" = start ]; then
  [[ $3 =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || refuse "the template is not a template name"
  tmpl=$3
  [[ $4 =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_][A-Za-z0-9._-]*#[1-9][0-9]*$ ]] || refuse "the task is not OWNER/REPO#N"
  task=$4
  jq -e --arg n "$tmpl" '.enable == true and (.eligibleTemplates | index($n) != null)' "$host_policy" >/dev/null \
    || refuse "template $tmpl is not eligible on this host"
  manifest=$(realpath -e -- "$manifests/$tmpl.json" 2>/dev/null) || refuse "template $tmpl has no manifest in the host's template profile"
  [[ $manifest == /nix/store/* ]] || refuse "the manifest of $tmpl is not in the store"
  jq -e --arg n "$tmpl" '.kind == "agent-runtime-template" and .template.name == $n and .session != null' "$manifest" >/dev/null 2>&1 \
    || refuse "template $tmpl is not a session template"
  entrypoint=$(jq -r '.entrypoint // ""' "$manifest")
  [[ $entrypoint == /nix/store/* ]] && [ -x "$entrypoint" ] || refuse "the manifest entrypoint is not an executable in the store"
  cred=$(jq -r '.session.credentialFile // empty' "$host_policy")
  user=$(jq -r '.session.attachUser // empty' "$host_policy")
  cred_args=()
  [ -z "$cred" ] || cred_args=(--credential "$cred")

  s=$("$instance" status "$id") || refuse "status lookup failed"
  case $(jq -r .state <<<"$s") in
    absent)
      pre=(--no-herdr --template "$manifest" "${cred_args[@]}")
      [ -z "$user" ] || pre+=(--herdr-user "$user")
      if ! out=$("$preflight" "${pre[@]}" 2>&1); then
        grep -E '^(FAIL|preflight:)' <<<"$out" >&2 || true
        refuse "the preflight is no-go"
      fi
      "$instance" create "$id" --template "$manifest" --task "$task" >/dev/null || refuse "create failed"
      ;;
    created)
      jq -e --arg n "$tmpl" --arg t "$task" '.template.name == $n and .task == $t' <<<"$s" >/dev/null \
        || refuse "$id exists for another template or task"
      ;;
    starting | running)
      jq -e --arg n "$tmpl" --arg t "$task" '.template.name == $n and .task == $t' <<<"$s" >/dev/null \
        || refuse "$id is running for another template or task"
      audit noop "the session is already running" || true
      echo running
      exit 0 ;;
    *) refuse "$id is $(jq -r .state <<<"$s"); end it first" ;;
  esac
  audit authorized "starting the manifest entrypoint $entrypoint" \
    || { echo "agent-runtime-session-launch: could not write the audit record to the journal; starting nothing" >&2; exit 1; }
  # no payload after `--`: start derives a session's argv from the manifest
  if ! "$instance" start "$id" "${cred_args[@]}" >/dev/null; then
    "$instance" destroy "$id" --discard >/dev/null 2>&1 || true
    refuse "start failed; the instance was discarded"
  fi
  echo started
  exit 0
fi

# end: serialized, so the session watcher and an operator's `end` never export twice; whoever comes
# second finds the instance gone and reports the same bundle. One JSON line: {outcome, bundle}.
mkdir -p "$rundir"
exec 7>"$rundir/.session-end-$id.lock"
flock -w 120 7 || refuse "another end of $id is still running"
bundle=$state/exports/$id.runs/latest
report() {  # the newest bundle's outcome and path, or OUTCOME with no bundle
  if [ -f "$bundle/bundle.json" ]; then
    jq -c --arg b "$(realpath "$bundle")" '{outcome: (.outcome // "unknown"), bundle: $b}' "$bundle/bundle.json"
  else
    jq -nc --arg o "$1" '{outcome: $o, bundle: null}'
  fi
}
s=$("$instance" status "$id") || refuse "status lookup failed"
st=$(jq -r .state <<<"$s")
if [ "$st" = absent ]; then
  audit noop "the session is already gone" || true
  report unknown
  exit 0
fi
tmpl=$(jq -r '.template.name // ""' <<<"$s") task=$(jq -r '.task // ""' <<<"$s")
jq -e '.session != null' "$state/$id/template.json" >/dev/null 2>&1 || refuse "$id is not a session instance"
audit authorized "ending the session (was $st)" || true
case $st in
  created | starting | running | cancelling) "$instance" cancel "$id" >/dev/null || refuse "cancel failed" ;;
esac
if [ -f "$state/$id/started.json" ]; then
  "$instance" export "$id" >/dev/null || refuse "export failed; the instance is kept"
  "$instance" destroy "$id" >/dev/null || refuse "destroy failed after the export"
  report unknown
else
  "$instance" destroy "$id" --discard >/dev/null || refuse "destroy failed"
  jq -nc '{outcome: "discarded", bundle: null}'
fi
