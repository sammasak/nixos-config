# agent-runtime-export: the writable checkouts under ROOT become OUT/<name>.patch
# (diff -ruN --no-dereference against the pinned store path, so a symlink is a
# link, not its target), OUT/<name>.json (base, changed paths,
# patch digest) and OUT/export.json. Clears ROOT/export-pending on success and
# never deletes anything: a failed export leaves the only work copy in place.
# Exit 2 usage, 1 failure.
usage() { echo 'usage: agent-runtime-export --root DIR --out DIR' >&2; exit 2; }
fail() { jq -nc --arg class "$1" --arg message "$2" '{error:{class:$class,message:$message}}' >&2; exit "$3"; }

root='' out=''
while [ $# -gt 0 ]; do
  case $1 in
    --root) root=${2:-}; shift 2 ;;
    --out) out=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$root" ] && [ -n "$out" ] || usage
[ -f "$root/materialized.json" ] || fail usage "$root is not materialized" 2
mkdir -p "$out"

summary='{}'
while IFS= read -r name; do
  src=$(jq -c --arg n "$name" '.sources[$n]' "$root/materialized.json")
  sp=$(jq -r .storePath <<<"$src")
  dest=$(jq -r .source <<<"$src")
  patch=$out/$name.patch
  rc=0
  diff -ruN --no-dereference "$sp" "$dest" >"$patch" || rc=$?
  [ "$rc" -le 1 ] || fail export "$name: diff of $dest against $sp failed ($rc); $root is untouched" 1
  changed=$(awk -v pre="$dest/" '/^diff -ruN / { p = $NF; if (index(p, pre) == 1) p = substr(p, length(pre) + 1); print p }' "$patch" \
    | jq -R . | jq -sc .)
  jq -n --argjson base "$(jq -c '{rev, narHash, storePath}' <<<"$src")" --argjson changed "$changed" \
    --arg patch "$name.patch" --arg sum "$(sha256sum "$patch" | cut -d' ' -f1)" --argjson bytes "$(stat -c %s "$patch")" \
    '{base: $base, changedPaths: $changed, patch: $patch, patchSha256: $sum, patchBytes: $bytes}' >"$out/$name.json"
  summary=$(jq -c --arg n "$name" --argjson c "$changed" --arg p "$name.patch" '.[$n] = {changed: ($c | length), patch: $p}' <<<"$summary")
done < <(jq -r '.sources | to_entries[] | select(.value.mode == "rw") | .key' "$root/materialized.json")

jq -n --slurpfile m "$root/materialized.json" --argjson s "$summary" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{schemaVersion: 1, kind: "agent-runtime-export", run: $m[0].run, template: $m[0].template, exportedAt: $at, sources: $s}' \
  >"$out/export.json"
rm -f "$root/export-pending"
