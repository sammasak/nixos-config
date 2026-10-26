set -euo pipefail

agent_kind=$1
shift

run_native() {
  exec "$agent_kind" "$@"
}

is_noninteractive_mode() {
  local kind=$1
  shift

  case "$kind" in
    pi)
      local arg
      for arg in "$@"; do
        case "$arg" in
          -p|--print|--export|--export=*|--list-models|--list-models=*|-h|--help|-V|--version)
            return 0
            ;;
        esac
      done
      while (($#)); do
        if [[ "$1" == --mode && $# -gt 1 ]]; then
          case "$2" in
            json|rpc) return 0 ;;
          esac
          shift
        fi
        shift
      done
      ;;
    claude)
      local first=${1-}
      local arg
      case "$first" in
        auth|mcp|plugin|doctor|update|install|setup-token|agents|-p|--print|-h|--help|-V|--version)
          return 0
          ;;
      esac
      for arg in "$@"; do
        case "$arg" in
          -p|--print) return 0 ;;
        esac
      done
      ;;
    codex)
      local command_name=
      local skip_value=0
      local arg
      while (($#)); do
        arg=$1
        shift
        if ((skip_value)); then
          skip_value=0
          continue
        fi
        case "$arg" in
          -c|--config|-m|--model|-p|--profile|-s|--sandbox|-a|--ask-for-approval|-C|--cd|--add-dir|--enable|--disable|--local-provider|-i|--image)
            skip_value=1
            ;;
          -h|--help|-V|--version)
            return 0
            ;;
          --) command_name=${1-}; break ;;
          -*) ;;
          *) command_name=$arg; break ;;
        esac
      done
      case "$command_name" in
        exec|e|review|login|logout|mcp|plugin|app-server|completion|update|doctor|sandbox|debug|apply|a|agents|remote-control|queue|archive|delete|migrate-rollouts|unarchive|fork|cloud|exec-server|features|help)
          return 0
          ;;
      esac
      ;;
  esac

  return 1
}

resume_reference() {
  case "$agent_kind:$#:${1-}" in
    pi:2:--session) printf '%s\n' "$2" ;;
    pi:1:--session=*) printf '%s\n' "${1#--session=}" ;;
    claude:2:--resume|claude:2:-r) printf '%s\n' "$2" ;;
    claude:1:--resume=*) printf '%s\n' "${1#--resume=}" ;;
    codex:2:resume) printf '%s\n' "$2" ;;
    *) return 1 ;;
  esac
}

if [[ ! -t 0 || ! -t 1 ]] \
  || [[ -n "${HERDR_ENV:-}" || -n "${HERDR_AUTOATTACH_DISABLED:-}" || -n "${CI:-}" ]] \
  || [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_CLIENT:-}" || -n "${SSH_TTY:-}" ]] \
  || is_noninteractive_mode "$agent_kind" "$@"; then
  run_native "$@"
fi

resume_args=("$@")
# claude-bypass appends `--settings <layer> --dangerously-skip-permissions`;
# without stripping it, a bypass --resume opens a second pane on a live session.
if [[ $agent_kind == claude && $# -ge 3 && ${resume_args[-1]} == --dangerously-skip-permissions \
  && ${resume_args[-3]} == --settings ]]; then
  resume_args=("${resume_args[@]:0:$#-3}")
fi

if resume_ref=$(resume_reference "${resume_args[@]}"); then
  if existing_pane=$(herdr agent list 2>/dev/null | jq -er \
    --arg kind "$agent_kind" --arg ref "$resume_ref" '
      [.result.agents[]? | select(.agent == $kind) |
        select((.agent_session.value // "") == $ref or
          ($kind == "pi" and ((.agent_session.value // "") | endswith("/" + $ref + ".jsonl")))) |
        .pane_id] | first // empty
    ' 2>/dev/null); then
    exec herdr agent attach "$existing_pane"
  fi
fi

created=$(herdr workspace create --cwd "$PWD" --label "$agent_kind" --no-focus 2>/dev/null) || run_native "$@"
workspace_id=$(jq -er '.result.workspace.workspace_id' <<<"$created" 2>/dev/null) || run_native "$@"
pane_id=$(jq -er '.result.root_pane.pane_id' <<<"$created" 2>/dev/null) || run_native "$@"
agent_name="cli-${agent_kind}-$(tr '[:upper:]' '[:lower:]' <<<"$workspace_id")"

if ! herdr agent start "$agent_name" --kind "$agent_kind" --pane "$pane_id" -- "$@" >/dev/null; then
  printf 'Herdr could not start %s in workspace %s; leaving it available for inspection.\n' "$agent_kind" "$workspace_id" >&2
  exit 1
fi

exec herdr agent attach "$agent_name"
