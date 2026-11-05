# agent-runtime-export: every checkout named in ROOT/export-pending becomes
# OUT/<name>.patch (git diff-tree --binary between the pinned tree and the
# checkout: content, binaries, symlinks, modes, empty files; reapply with
# git apply), OUT/<name>.json and OUT/export.json, written last. The exported
# tree ids go to ROOT/exported.json so reclaim can refuse a checkout that
# changed afterwards. Removes export-pending on success and deletes nothing else.
USAGE='agent-runtime-export --root DIR --out DIR'
root='' out=''
while [ $# -gt 0 ]; do
  case $1 in
    --root) [ $# -ge 2 ] || usage; root=$2; shift 2 ;;
    --out) [ $# -ge 2 ] || usage; out=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$root" ] && [ -n "$out" ] || usage
[ -f "$root/materialized.json" ] || fail state "$root is not materialized"
[ -e "$root/reclaimed" ] && fail state "$root was reclaimed; there is nothing left to export"
[ -f "$root/export-pending" ] || fail state "$root has no export-pending list: already exported"
[ -e "$out/export.json" ] && fail state "$out/export.json exists; export into a fresh directory"
exec 9>"$root/.lock"
flock -n 9 || fail state "$root is in use by another export or reclaim"
mkdir -p "$out"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
git_scratch "$scratch/repo"
mkdir "$scratch/out"
summary='{}' trees='{}' base='' current=''
while IFS= read -r name; do
  src=$(jq -ec --arg n "$name" '.sources[$n] | select(.mode == "rw")' "$root/materialized.json") \
    || fail state "$name is export-pending but not a writable source of $root"
  store_path=$(jq -r .storePath <<<"$src")
  checkout=$(jq -r .source <<<"$src")
  [ -d "$checkout" ] || fail state "$name: $checkout is missing; nothing is exported and the marker stays"
  [ -z "$(find "$checkout" -mindepth 2 -name .git -print -quit)" ] \
    || fail export "$name: a nested repository in $checkout cannot be exported; remove its .git first"
  tree_of base "$store_path"
  tree_of current "$checkout" "$base"
  patch=$scratch/out/$name.patch
  git diff-tree -p --binary "$base" "$current" >"$patch" || fail export "$name: git diff-tree failed; $root is untouched"
  changed=$(git diff-tree -r --name-only -z "$base" "$current" | jq -Rsc 'split("\u0000") | map(select(length > 0))')
  jq -n --argjson src "$src" --argjson changed "$changed" --arg patch "$name.patch" \
    --arg sum "$(sha256sum "$patch" | cut -d' ' -f1)" --arg tree "$current" \
    '{base: ($src | {rev, narHash, storePath}), tree: $tree, changedPaths: $changed, patch: $patch, patchSha256: $sum}' \
    >"$scratch/out/$name.json"
  summary=$(jq -c --arg n "$name" --argjson c "$changed" '.[$n] = {changed: ($c | length)}' <<<"$summary")
  trees=$(jq -c --arg n "$name" --arg t "$current" '.[$n] = $t' <<<"$trees")
done <"$root/export-pending"

mv "$scratch"/out/* "$out/"
jq -n --slurpfile m "$root/materialized.json" --argjson s "$summary" --arg at "$(now)" \
  '{schemaVersion: 1, kind: "agent-runtime-export", run: $m[0].run, template: $m[0].template, exportedAt: $at, sources: $s}' \
  >"$scratch/export.json"
printf '%s\n' "$trees" >"$scratch/exported.json"
trap '' INT TERM
mv "$scratch/exported.json" "$root/exported.json"
mv "$scratch/export.json" "$out/export.json"
rm -f "$root/export-pending"
