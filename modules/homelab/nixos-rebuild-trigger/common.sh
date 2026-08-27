# Audit helpers shared by trigger.sh and activate.sh. Not a standalone script:
# default.nix prepends it to each of them so both units emit byte-identical line
# formats — a poller or log reader cannot tell which unit wrote a given line,
# and should not need to.
#
# Callers must set REQUESTER and TS, and must have contract-checked AUDIT_LOG
# and RESULT_FILE, before the first call. REV is optional and renders as `none`.
# Nothing here runs at load time: trigger.sh consumes the request file before
# any other statement, and a helper that could exit first would re-arm the path
# unit into a loop.

# Append-only, outside /run so it survives reboots.
audit() {
  printf '%s requester=%s rev=%s %s\n' \
    "$(date -Iseconds)" "$REQUESTER" "${REV:-none}" "$1" >>"$AUDIT_LOG"
}

result() {
  printf 'start=%s requester=%s rev=%s status=%s\n' \
    "$TS" "$REQUESTER" "${REV:-none}" "$1" >"$RESULT_FILE"
}
