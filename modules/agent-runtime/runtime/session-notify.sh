# shellcheck shell=bash
# agent-runtime-session-notify: the default session hook (sam.agentRuntime.session.hooks), one Herdr
# notification per lifecycle event. It runs as the session user and reads only the non-secret
# AGENT_RUNTIME_SESSION_* variables the watcher sets (docs/agent-runtime-session.md).
id=${AGENT_RUNTIME_SESSION_ID:?not run as a session hook}
host=${AGENT_RUNTIME_SESSION_HOST:-}
task=${AGENT_RUNTIME_SESSION_TASK:-}
case ${AGENT_RUNTIME_SESSION_EVENT:-} in
  start)
    title="rt-$id started on $host"
    body="${AGENT_RUNTIME_SESSION_TEMPLATE:-} $task"
    sound=none
    ;;
  end)
    outcome=${AGENT_RUNTIME_SESSION_OUTCOME:-unknown}
    title="rt-$id $outcome on $host"
    body="$task ${AGENT_RUNTIME_SESSION_BUNDLE:-no bundle}"
    [ -z "${AGENT_RUNTIME_SESSION_ERROR:-}" ] || body+=" (${AGENT_RUNTIME_SESSION_ERROR})"
    sound=request
    if [ "$outcome" = succeeded ]; then sound="done"; fi
    ;;
  *) exit 0 ;;
esac
exec herdr notification show "$title" --body "$body" --sound "$sound"
