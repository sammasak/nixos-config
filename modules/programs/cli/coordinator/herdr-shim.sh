#!/usr/bin/env bash
# Forced command for the coordinator's SSH key on a worker host: the only remote
# surface it gets. The coordinator tasks send `bash -c '<runner>' _ <base64 of
# NUL-separated argv>`; the shim decodes that argv itself (never eval, never a
# shell re-parse) and execs it only when it is a read-only herdr verb, the
# prompt verb (herdr:message is the role's single act task), or one of the two
# exact session-read one-liners harness:session-summary ships.
set -euo pipefail
orig="${SSH_ORIGINAL_COMMAND:-}"
[ -n "$orig" ] || { echo "herdr-shim: interactive sessions are not allowed for this key" >&2; exit 2; }
[[ "$orig" =~ ^bash\ -c\ \'[^\']*\'\ _\ ([A-Za-z0-9+/=]+)$ ]] || { echo "herdr-shim: only the coordinator transport is accepted" >&2; exit 2; }
blob=$(printf '%s' "${BASH_REMATCH[1]}" | base64 -d 2>/dev/null | tr '\0' '\n'; printf x); blob="${blob%x}"
[ -n "$blob" ] || { echo "herdr-shim: bad transport" >&2; exit 2; }
mapfile -d '' a < <(printf '%s' "${BASH_REMATCH[1]}" | base64 -d)
[ "${#a[@]}" -ge 3 ] || { echo "herdr-shim: too few words" >&2; exit 2; }
case "${a[0]} ${a[1]} ${a[2]}" in
  "herdr agent list"|"herdr agent get"|"herdr agent read"|"herdr agent wait"|"herdr agent prompt") exec "${a[@]}" ;;
  "bash -c "*)
    # harness:session-summary ships exactly one of two one-liners that read a session file under the
    # login user's Claude or Pi store; paths are confined to those stores (no other file is readable here)
    [ "${#a[@]}" -eq 3 ] || { echo "herdr-shim: session read takes exactly one script" >&2; exit 2; }
    script="${a[2]}"
    home_re='(\$HOME|'"$(printf '%s' "$HOME" | sed 's/[][\.*^$/]/\\&/g')"')'
    claude_re="^f=${home_re}/\.claude/projects/[A-Za-z0-9-]+/[A-Za-z0-9-]+\.jsonl; \[ -r \"\\\$f\" \] \|\| exit 44; tail -n [0-9]{1,3} \"\\\$f\"\$"
    pi_re="^d=${home_re}/\.pi/agent/sessions/-[A-Za-z0-9-]+--; f=\\\$\(ls -t \"\\\$d\"/\*_[A-Za-z0-9_-]+\.jsonl 2>/dev/null \| head -1\); \[ -n \"\\\$f\" \] \|\| exit 44; tail -n [0-9]{1,3} \"\\\$f\"\$"
    { [[ "$script" =~ $claude_re ]] || [[ "$script" =~ $pi_re ]]; } && [[ "$script" != *..* ]] || { echo "herdr-shim: session read form not allowed: $script" >&2; exit 2; }
    exec bash -c "$script" ;;
  *) echo "herdr-shim: command not allowed for the coordinator key: ${a[*]}" >&2; exit 2 ;;
esac
