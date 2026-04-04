#!/usr/bin/env bash
set -euo pipefail

INPUT=$(cat)
EVENT_NAME=$(echo "$INPUT" | jq -r '.hook_event_name // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty')

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$HOME/workspace}"
ROUTER_FILE="$WORKSPACE_ROOT/CLAUDE.md"

if [ ! -f "$ROUTER_FILE" ]; then
  exit 0
fi

under_workspace=false
if [ -n "$CWD" ] && [ "$CWD" != "null" ]; then
  case "$CWD" in
    "$WORKSPACE_ROOT"|"$WORKSPACE_ROOT"/*) under_workspace=true ;;
  esac
fi

if [ "$under_workspace" = false ]; then
  case "$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]')" in
    *workspace*|*homelab*|*doable*|*claude-ctl*|*forge*|*jarvis*|*learn-platform*|*component-store*|*system-prompts*|*arrow-js*)
      ;;
    *)
      exit 0
      ;;
  esac
fi

context_lines=()
context_lines+=("Use $ROUTER_FILE as the workspace router before making assumptions.")

if [ "$under_workspace" = true ]; then
  relative_path="${CWD#"$WORKSPACE_ROOT"/}"
  if [ "$CWD" = "$WORKSPACE_ROOT" ]; then
    relative_path="."
  fi
  context_lines+=("The current working directory is inside the knowledge graph at $CWD.")

  current="$CWD"
  while :; do
    if [ -f "$current/CONTEXT.md" ]; then
      context_lines+=("Load $current/CONTEXT.md for room-specific instructions.")
    elif [ -f "$current/INDEX.md" ]; then
      context_lines+=("Load $current/INDEX.md because CONTEXT.md is absent there.")
    fi

    if [ "$current" = "$WORKSPACE_ROOT" ]; then
      break
    fi
    current=$(dirname "$current")
    case "$current" in
      "$WORKSPACE_ROOT"|"$WORKSPACE_ROOT"/*) ;;
      *) break ;;
    esac
  done

  context_lines+=("Prefer the room closest to $relative_path when multiple rooms apply.")
else
  context_lines+=("The prompt appears to reference your workspace; consult the relevant room CONTEXT.md files after routing through CLAUDE.md.")
fi

context_lines+=("Inside ~/workspace, use INDEX.md only as a fallback signal. CONTEXT.md is the main room payload.")

context=$(printf '%s\n' "${context_lines[@]}" | awk '!seen[$0]++' | paste -sd ' ' -)

jq -nc \
  --arg event "$EVENT_NAME" \
  --arg context "$context" \
  '{
    hookSpecificOutput: {
      hookEventName: $event,
      additionalContext: $context
    }
  }'
