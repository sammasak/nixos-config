# agent-runtime-reclaim: remove an instance's workspace, refusing while
# ROOT/export-pending exists so no source state disappears before export.
# materialized.json stays as the record; ROOT/reclaimed carries the time.
USAGE='agent-runtime-reclaim --root DIR'
root=''
while [ $# -gt 0 ]; do
  case $1 in
    --root) [ $# -ge 2 ] || usage; root=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$root" ] || usage
[ -f "$root/materialized.json" ] || fail usage "$root is not materialized"
[ -e "$root/export-pending" ] \
  && fail state "$root: export pending for $(paste -sd' ' "$root/export-pending"); run agent-runtime-export first"
rm -rf "$root/workspace"
now >"$root/reclaimed"
