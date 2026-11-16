# shellcheck shell=bash
# coordinator-report daily|fortnight [devenv args...]
#
# The coordinator-report timers' job, run in the skills checkout. daily runs
# coord:report:daily (the task defaults to yesterday, UTC). fortnight acts on
# even ISO weeks only: until the bi-weekly review task exists in skills, it
# renders coord:report:weekly for the two ISO weeks before this one and stops.
# The remaining arguments go to every devenv call (the host's --option flags).
set -euo pipefail

mode=${1:-}
[ "$#" -gt 0 ] && shift
log() { printf 'coordinator-report: %s\n' "$*"; }

case $mode in
  daily) ;;
  fortnight)
    # 10#: weeks 08 and 09 are not octal
    week=$((10#$(date +%V)))
    if ((week % 2)); then
      log "ISO week $week is odd; the bi-weekly run is on even weeks"
      exit 0
    fi
    ;;
  *)
    echo "coordinator-report: usage: coordinator-report daily|fortnight [devenv args...]" >&2
    exit 2
    ;;
esac

skills=${COORDINATOR_SKILLS_DIR:-$HOME/claude-code-skills}
[ -r "$skills/devenv.nix" ] || { log "no skills checkout at $skills; nothing run"; exit 0; }
cd "$skills"

if [ "$mode" = daily ]; then
  exec devenv tasks run coord:report:daily --show-output "$@"
fi
for back in 14 7; do
  anchor=$(date -d "-$back days" +%F)
  log "ISO week $week: rendering the weekly of $anchor's week"
  devenv tasks run coord:report:weekly --input-json "{\"anchor\":\"$anchor\"}" --show-output "$@"
done
