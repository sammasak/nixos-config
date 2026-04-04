#!/usr/bin/env bash
set -euo pipefail

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

[ -z "$CMD" ] && exit 0

ALT_FILE="$HOME/workspace/workflows/hooks/validate-bash/alternatives.md"

lookup_suggestion() {
  local pattern="$1"
  [ -f "$ALT_FILE" ] || return 0
  grep -i "$pattern" "$ALT_FILE" 2>/dev/null | head -1 | awk -F'|' '{print $3}' | xargs || true
  return 0
}

block() {
  local reason="$1"
  jq -nc --arg reason "$reason" '{ decision: "block", reason: $reason }'
  exit 0
}

if printf '%s' "$CMD" | grep -qE 'git push.*(--force([^-]|$)|-f\b)'; then
  suggestion=$(lookup_suggestion "force.push")
  block "Force push to main is not allowed.${suggestion:+ Try: $suggestion}"
fi

if printf '%s' "$CMD" | grep -qE 'sops.*-e.*/tmp/|sops.*encrypt.*/tmp/'; then
  suggestion=$(lookup_suggestion 'sops.*tmp')
  block "SOPS encryption from /tmp is unsafe.${suggestion:+ Try: $suggestion}"
fi

if [ -d "${CLAUDE_WORKER_HOME:-/var/lib/claude-worker}" ]; then
  if printf '%s' "$CMD" | grep -qE 'cargo build|cargo test' && ! printf '%s' "$CMD" | grep -qE 'musl|x86_64-unknown-linux-musl'; then
    suggestion=$(lookup_suggestion 'musl')
    block "Rust binaries in claude-worker environments must use --target x86_64-unknown-linux-musl.${suggestion:+ Try: $suggestion}"
  fi

  if printf '%s' "$CMD" | grep -qE 'buildah push' && ! printf '%s' "$CMD" | grep -q 'authfile'; then
    suggestion=$(lookup_suggestion 'authfile')
    block "buildah push requires --authfile in claude-worker environments.${suggestion:+ Try: $suggestion}"
  fi
fi
