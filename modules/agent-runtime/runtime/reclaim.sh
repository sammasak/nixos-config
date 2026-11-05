# agent-runtime-reclaim: remove an instance's workspace. Refuses while
# ROOT/export-pending exists, and while any exported checkout differs from the
# tree export recorded, so no source state disappears unexported. Idempotent.
USAGE='agent-runtime-reclaim --root DIR'
root=''
while [ $# -gt 0 ]; do
  case $1 in
    --root) [ $# -ge 2 ] || usage; root=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$root" ] || usage
[ -f "$root/materialized.json" ] || fail state "$root is not materialized"
[ -e "$root/reclaimed" ] && exit 0
[ -e "$root/export-pending" ] \
  && fail state "$root: export pending for $(paste -sd' ' "$root/export-pending"); run agent-runtime-export first"
exec 9>"$root/.lock"
flock -n 9 || fail state "$root is in use by another export or reclaim"
if [ -f "$root/exported.json" ]; then
  scratch=$(mktemp -d)
  trap 'rm -rf "$scratch"' EXIT
  git_scratch "$scratch/repo"
  base='' current=''
  for name in $(jq -r 'keys[]' "$root/exported.json"); do
    checkout=$(jq -r --arg n "$name" '.sources[$n].source' "$root/materialized.json")
    [ -d "$checkout" ] || continue
    tree_of base "$(jq -r --arg n "$name" '.sources[$n].storePath' "$root/materialized.json")"
    tree_of current "$checkout" "$base"
    [[ $current == $(jq -r --arg n "$name" '.[$n]' "$root/exported.json") ]] \
      || fail state "$name changed after it was exported; export again before reclaiming"
  done
fi
rm -rf "$root/workspace"
now >"$root/reclaimed"
