# shellcheck shell=bash
# agent-runtime-pane: the process `agent-runtime-herdr attach` runs in a runtime's Herdr pane (#165,
# the pane the E2E test proved). It reports started and idle through the status file the adapter
# follows, waits for the one handoff `agent-runtime-herdr deliver` types into its PTY, then runs
# the instance to its outcome and reports finished. The instance tool needs root: a pane of a
# user's Herdr server (acer-swift) runs it through sudo, which asks in this pane.
USAGE='agent-runtime-pane ID STATUS-FILE -- PROGRAM [ARG]...'
usage() { echo "usage: $USAGE" >&2; exit 2; }
[ $# -ge 4 ] && [ "$3" = -- ] || usage
id=$1 status=$2
shift 3
echo started >>"$status"
echo idle >>"$status"
read -r handoff || true
printf 'handoff for %s: %s\n' "$id" "$handoff"
echo working >>"$status"
# the instance tool this pane was built with, by absolute path: sudo resolves through its secure_path
instance=("$(command -v agent-runtime-instance)")
[ "$(id -u)" = 0 ] || instance=(/run/wrappers/bin/sudo "${instance[0]}")
rc=0
"${instance[@]}" start "$id" --wait -- "$@" || rc=$?
echo finished >>"$status"
printf 'instance %s ended with exit %d\n' "$id" "$rc"
exit "$rc"
