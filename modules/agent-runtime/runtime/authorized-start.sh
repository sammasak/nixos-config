# shellcheck shell=bash
# agent-runtime-authorized-start: the one privileged entry point that an authorized
# Coordinator may hold a NOPASSWD sudo rule for (#170). It takes ONLY a bounded
# runtime id and derives the whole root-run payload from the template manifest, never
# from the caller: `start` itself re-checks nothing but state == created and runs an
# arbitrary payload after `--`, so any `start`-level sudo rule would be arbitrary root.
# This fails closed (starts nothing) unless every precondition holds, and accepts no
# flags, no payload, no paths. `@instance@` is the agent-runtime-instance store path,
# substituted by runtime.nix at build time (never a PATH lookup).
instance="@instance@"
host_policy=/etc/agent-runtime/host.json

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# A single structured audit line to stdout for every decision; nothing here is secret.
audit() {  # ID TEMPLATE TASK DIGESTS DECISION REASON
  jq -nc --arg at "$(now)" --arg id "$1" --arg template "$2" --arg task "$3" \
    --argjson digests "$4" --arg decision "$5" --arg reason "$6" \
    '{kind: "agent-runtime-authorized-start", at: $at, id: $id, template: $template,
      task: $task, digests: $digests, decision: $decision, reason: $reason}'
}

id='' tmpl='' task='' digests=null
refuse() {  # REASON: audit the refusal and exit non-zero, having started nothing
  audit "$id" "$tmpl" "$task" "$digests" refused "$1"
  exit 1
}

# Exactly one argument, a runtime id: no flags, no payload, no second path.
[ $# -eq 1 ] || { audit "" "" "" null refused "exactly one argument (a runtime id) is required"; exit 2; }
id=$1

# The same strict id charset as agent-runtime-instance (a DNS label, no `/`, no `..`).
[[ $id =~ ^[a-z0-9]([a-z0-9-]{0,27}[a-z0-9])?$ ]] || refuse "id is not a valid runtime id"
case $id in */* | *..*) refuse "id must not contain a path component" ;; esac
[ "$id" != exports ] || refuse "id is reserved"

[ -f "$host_policy" ] || refuse "host policy $host_policy is absent"

# status is the tool's own view of the lifecycle; it carries the recorded template.
s=$("$instance" status "$id") || refuse "status lookup failed"
state=$(jq -r '.state' <<<"$s")
case $state in
  created) ;;
  # Already acted on: never re-start (start would refuse anyway). Idempotent no-op, exit 0.
  starting | running | cancelling | succeeded | failed | timed-out | oom-killed | cancelled)
    audit "$id" "$(jq -r '.template.name // ""' <<<"$s")" "$(jq -r '.task // ""' <<<"$s")" \
      "$(jq -c '.template.digests // null' <<<"$s")" noop "instance is already $state; not re-started"
    exit 0 ;;
  *) refuse "instance is $state, not created" ;;
esac

tmpl=$(jq -r '.template.name // ""' <<<"$s")
task=$(jq -r '.task // ""' <<<"$s")
digests=$(jq -c '.template.digests // null' <<<"$s")
manifest=$(jq -r '.template.manifest // ""' <<<"$s")

[ -n "$task" ] || refuse "instance has no recorded task"

# Re-check the eligibility that start skips: the recorded template must still be admitted
# by the host policy (enable true and listed), not a stale or since-revoked approval.
jq -e --arg n "$tmpl" '.enable == true and (.eligibleTemplates | index($n) != null)' "$host_policy" >/dev/null \
  || refuse "template $tmpl is not eligible on this host"

# The recorded digests must equal the digests of the manifest the record points at: a
# template that changed since create, or a forged instance.json, is refused.
[[ $manifest == /nix/store/* ]] || refuse "recorded manifest path is not in the store"
[ -f "$manifest" ] || refuse "recorded manifest $manifest is absent"
jq -e -n --argjson a "$digests" --argjson b "$(jq -c '.digests' "$manifest")" '$a == $b' >/dev/null \
  || refuse "recorded digests do not match the manifest at $manifest"

# The payload is the manifest's own declared entrypoint, and it must be a real executable.
entrypoint=$(jq -r '.entrypoint // ""' "$manifest")
[ -n "$entrypoint" ] || refuse "manifest declares no entrypoint"
[[ $entrypoint == /nix/store/* ]] || refuse "entrypoint is not in the store"
[ -x "$entrypoint" ] || refuse "entrypoint $entrypoint is not an executable file"

audit "$id" "$tmpl" "$task" "$digests" authorized "starting with the manifest entrypoint $entrypoint"
# --wait so the sudo caller gets the run's outcome as the exit code; no other argument is passed.
exec "$instance" start "$id" --wait -- "$entrypoint"
