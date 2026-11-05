# agent-runtime-reclaim: remove an instance's writable workspace, refusing while
# ROOT/export-pending exists so no source state disappears before export.
# Exit 2 usage, 1 refused.
usage() { echo 'usage: agent-runtime-reclaim --root DIR' >&2; exit 2; }
fail() { jq -nc --arg class "$1" --arg message "$2" '{error:{class:$class,message:$message}}' >&2; exit "$3"; }

root=''
while [ $# -gt 0 ]; do
  case $1 in
    --root) root=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$root" ] || usage
[ -f "$root/materialized.json" ] || fail usage "$root is not materialized" 2
[ -e "$root/export-pending" ] \
  && fail state "$root: export pending for $(tr '\n' ' ' <"$root/export-pending"| sed 's/ $//'); run agent-runtime-export first" 1
rm -rf "$root/workspace"
date -u +%Y-%m-%dT%H:%M:%SZ >"$root/reclaimed"
