#!/usr/bin/env bash
# Forced command for the coordinator's SSH key on a worker host: the only remote
# surface it gets. Accepts the base64 transport the skills tasks use
# (`echo <b64> | base64 -d | bash`), decodes it, and runs the inner argv only if
# it is one of the read-only herdr verbs or a bounded session-file read; the
# prompt verb is allowed because herdr:message is the role's single act task.
set -euo pipefail
orig="${SSH_ORIGINAL_COMMAND:-}"
[ -n "$orig" ] || { echo "herdr-shim: interactive sessions are not allowed for this key" >&2; exit 2; }
if [[ "$orig" =~ ^echo\ ([A-Za-z0-9+/=]+)\ \|\ base64\ -d\ \|\ bash$ ]]; then
  inner=$(printf '%s' "${BASH_REMATCH[1]}" | base64 -d 2>/dev/null) || { echo "herdr-shim: bad transport" >&2; exit 2; }
else
  inner="$orig"
fi
# the inner string is %q-quoted words; re-split with the shell, no expansion of anything else
eval "set -- $inner" 2>/dev/null || { echo "herdr-shim: unparseable command" >&2; exit 2; }
case "$*" in
  "herdr agent list"|"herdr agent get "*|"herdr agent read "*|"herdr agent wait "*|"herdr agent prompt "*) exec "$@" ;;
  "bash -c "*)
    # harness:session-summary ships `f=<store>/<slug>/<id>.jsonl; [ -r "$f" ] || exit 44; tail -n <N> "$f"` style one-liners
    script="$3"
    [[ "$script" =~ ^(f|d)=.*tail\ -n\ [0-9]+\ .*$ ]] && [[ "$script" != *';'*';'*';'*';'* ]] && [[ "$script" != *'$('* ]] && [[ "$script" != *'`'* ]] || { echo "herdr-shim: session read form not allowed: $script" >&2; exit 2; }
    exec bash -c "$script" ;;
  *) echo "herdr-shim: command not allowed for the coordinator key: $*" >&2; exit 2 ;;
esac
