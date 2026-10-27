#!/usr/bin/env bash
set -euo pipefail

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

[ -z "$CMD" ] && exit 0

block() {
  local reason="$1"
  jq -nc --arg reason "$reason" '{ decision: "block", reason: $reason }'
  exit 0
}

if printf '%s' "$CMD" | grep -qE 'git push.*(--force([^-]|$)|-f\b)'; then
  block "Force push to main is not allowed."
fi

if printf '%s' "$CMD" | grep -qE 'sops.*-e.*/tmp/|sops.*encrypt.*/tmp/'; then
  block "SOPS encryption from /tmp is unsafe."
fi
