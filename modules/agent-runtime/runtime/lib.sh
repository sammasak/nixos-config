# Prepended to each tool by runtime.nix. Every failure ends stderr with one JSON
# line and the class fixes the exit code; a command that fails outside an explicit
# check is reported as `state` rather than dying silently.
set -E
exit_code() {
  case $1 in
    usage) echo 2 ;; plan) echo 3 ;; github) echo 4 ;; credential) echo 5 ;;
    store) echo 6 ;; source) echo 8 ;; export) echo 9 ;; *) echo 1 ;;
  esac
}
fail() {
  trap - ERR
  jq -nc --arg class "$1" --arg message "$2" '{error: {class: $class, message: $message}}' >&2
  exit "$(exit_code "$1")"
}
trap 'fail state "unexpected failure: $BASH_COMMAND (line $LINENO)"' ERR
usage() { fail usage "usage: $USAGE"; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
