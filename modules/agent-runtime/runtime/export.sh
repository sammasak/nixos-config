# agent-runtime-export: every checkout named in ROOT/export-pending becomes
# OUT/<name>.patch (git diff-tree --binary between the pinned store tree and the
# checkout: content, binaries, symlinks, modes, empty files; reapply with
# git apply), OUT/<name>.json (base, changed paths, patch digest) and
# OUT/export.json. Removes export-pending on success and deletes nothing else.
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
[ -f "$root/materialized.json" ] || fail usage "$root is not materialized"
[ -e "$root/reclaimed" ] && fail state "$root was reclaimed; there is nothing left to export"
[ -f "$root/export-pending" ] || fail state "$root has no export-pending list: already exported"
mkdir -p "$out"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
git init -q "$scratch/repo"
export GIT_DIR=$scratch/repo/.git
# a tree object of a directory, read through a fresh index (.gitignore honoured)
tree_of() {
  rm -f "$GIT_DIR/index"
  GIT_WORK_TREE=$1 git -C "$1" add -A
  git write-tree
}

summary='{}'
while IFS= read -r name; do
  src=$(jq -ec --arg n "$name" '.sources[$n] | select(.mode == "rw")' "$root/materialized.json") \
    || fail state "$name is export-pending but not a writable source of $root"
  store_path=$(jq -r .storePath <<<"$src")
  checkout=$(jq -r .source <<<"$src")
  [ -d "$checkout" ] || fail state "$name: $checkout is missing; nothing is exported and the marker stays"
  base=$(tree_of "$store_path")
  current=$(tree_of "$checkout")
  patch=$out/$name.patch
  git diff-tree -p --binary --no-color "$base" "$current" >"$patch" || fail export "$name: git diff-tree failed; $root is untouched"
  changed=$(git diff-tree -r --name-only -z "$base" "$current" | jq -Rsc 'split("\u0000") | map(select(length > 0))')
  jq -n --argjson base "$(jq -c '{rev, narHash, storePath}' <<<"$src")" --argjson changed "$changed" \
    --arg patch "$name.patch" --arg sum "$(sha256sum "$patch" | cut -d' ' -f1)" \
    '{base: $base, changedPaths: $changed, patch: $patch, patchSha256: $sum}' >"$out/$name.json"
  summary=$(jq -c --arg n "$name" --argjson c "$changed" '.[$n] = {changed: ($c | length)}' <<<"$summary")
done <"$root/export-pending"

jq -n --slurpfile m "$root/materialized.json" --argjson s "$summary" --arg at "$(now)" \
  '{schemaVersion: 1, kind: "agent-runtime-export", run: $m[0].run, template: $m[0].template, exportedAt: $at, sources: $s}' \
  >"$out/export.json"
rm -f "$root/export-pending"
