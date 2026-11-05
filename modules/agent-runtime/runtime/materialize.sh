# agent-runtime-materialize: instantiate a run's sources under one instance root,
# without network. The template manifest and the run directory's GC roots are the
# trust anchors: the run must describe exactly the template's sources and name
# the store paths assign rooted. A read-only source is its verified store path;
# writable ones are copied into ROOT/workspace/<name> within the declared budget.
# A failed run leaves nothing under ROOT. Writes materialized.json, export-pending.
USAGE='agent-runtime-materialize --run DIR --template MANIFEST --root DIR'
run_dir='' template='' root=''
while [ $# -gt 0 ]; do
  case $1 in
    --run) [ $# -ge 2 ] || usage; run_dir=$2; shift 2 ;;
    --template) [ $# -ge 2 ] || usage; template=$2; shift 2 ;;
    --root) [ $# -ge 2 ] || usage; root=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$run_dir" ] && [ -n "$template" ] && [ -n "$root" ] || usage
run=$run_dir/run.json
[ -f "$run" ] || fail usage "run manifest not found: $run"
[ -f "$template" ] || fail usage "template manifest not found: $template"
jq -e '.kind == "agent-runtime-run" and .schemaVersion == 1 and (.sources | type == "object")' "$run" >/dev/null 2>&1 \
  || fail usage "$run is not an agent-runtime-run, schemaVersion 1"
jq -e '.kind == "agent-runtime-template" and .schemaVersion == 1' "$template" >/dev/null 2>&1 \
  || fail usage "$template is not an agent-runtime-template, schemaVersion 1"
jq -e --slurpfile t "$template" '
  .template.digests == $t[0].digests and .workspace == $t[0].filesystem.workspace
  and (.sources | keys) == ($t[0].sources | keys)
  and ([.sources | to_entries[] | .value as $r | $t[0].sources[.key] as $s
        | ($r | {github, ref, resolve, access, path, writable}) == ($s | {github, ref, resolve, access, path, writable})
        and ($s.resolve != "lock" or ($r.resolved | {rev, narHash, storePath}) == $s.locked)
        and ($r.resolved.rev | test("^[0-9a-f]{40}$"))] | all)
' "$run" >/dev/null 2>&1 \
  || fail source "$run does not describe the sources of $template (digests, names, paths, modes or locks differ)"
mkdir -p "$root"
root=$(realpath "$root")
# one materialize, export or reclaim per root at a time; the state checks hold only under the lock
exec 9>"$root/.lock"
flock -n 9 || fail state "$root is in use by another materialize, export or reclaim"
[ -e "$root/materialized.json" ] && fail state "$root is already materialized"
[ -e "$root/workspace" ] && fail state "$root/workspace exists; refusing to touch state this run did not create"
rm -rf "$root"/.materialized.* "$root"/.export-pending.*
mkdir "$root/workspace"
scratch=$(mktemp -d)
trap 'rm -rf "$root/workspace" "$root/export-pending" "$scratch"' EXIT

size_budget=$(( $(jq -r '.filesystem.workspaceBudget.sizeMiB' "$template") * 1024 * 1024 ))
inode_budget=$(jq -r '.filesystem.workspaceBudget.inodes' "$template")
size_used=0 inodes_used=0
record='{}'
names=$(jq -r '.sources | keys[]' "$run")
for name in $names; do
  src=$(jq -c --arg n "$name" '.sources[$n]' "$run")
  store_path=$(jq -r .resolved.storePath <<<"$src")
  expected_hash=$(jq -r .resolved.narHash <<<"$src")
  [[ $store_path =~ ^/nix/store/[a-z0-9]{32}-[A-Za-z0-9+._?=-]+$ && -d $store_path ]] \
    && [[ $(realpath -e "$store_path" 2>/dev/null) == "$store_path" ]] \
    || fail store "$name: $store_path is not a present top-level store path (a build or closure failure, not a GitHub one)"
  [[ $(realpath -e "$run_dir/gcroots/$name" 2>/dev/null) == "$store_path" ]] \
    || fail source "$name: $store_path is not the path assign rooted in $run_dir/gcroots"
  run_capture store "$name: cannot hash $store_path" nix_cmd hash path "$store_path"
  [[ $captured == "$expected_hash" ]] || fail store "$name: $store_path has NAR hash $captured, the run manifest says $expected_hash"
  writable=$(jq -r .writable <<<"$src")
  find "$store_path" -type l -print0 >"$scratch/links" || fail store "$name: cannot scan $store_path"
  while IFS= read -r -d '' link; do
    target=$(realpath -m "$link")
    case $target in
      "$store_path" | "$store_path"/*) ;;
      *) fail source "$name: symlink $link escapes the source tree ($target)" ;;
    esac
    [[ $writable != true || $(readlink "$link") != /* ]] \
      || fail source "$name: absolute symlink $link would point at the store, not the writable copy"
  done <"$scratch/links"
  if [[ $writable == true ]]; then
    size_used=$(( size_used + $(du -sb "$store_path" | cut -f1) ))
    inodes_used=$(( inodes_used + $(find "$store_path" | wc -l) ))
    [ "$size_used" -le "$size_budget" ] && [ "$inodes_used" -le "$inode_budget" ] \
      || fail budget "$name: the writable copies need $size_used bytes and $inodes_used inodes; the workspace budget is $size_budget bytes and $inode_budget inodes"
    host_path=$root/workspace/$name
    mkdir "$host_path"
    cp -a "$store_path/." "$host_path/"
    chmod -R u+w "$host_path"
    mode=rw
  else
    host_path=$store_path
    mode=ro
  fi
  record=$(jq -c --arg n "$name" --arg mode "$mode" --arg source "$host_path" --argjson s "$src" \
    '.[$n] = {mode: $mode, source: $source, path: $s.path} + ($s.resolved | {rev, narHash, storePath})' <<<"$record")
done

pending=$(mktemp "$root/.export-pending.XXXXXX")
jq -r 'to_entries[] | select(.value.mode == "rw") | .key' <<<"$record" >"$pending"
tmp=$(mktemp "$root/.materialized.XXXXXX")
jq -n --slurpfile r "$run" --argjson s "$record" \
  '{schemaVersion: 1, kind: "agent-runtime-instance", run: $r[0].run, template: $r[0].template,
    workspace: $r[0].workspace, sources: $s}' >"$tmp"
trap '' INT TERM
mv "$pending" "$root/export-pending"
ln "$tmp" "$root/materialized.json" || fail state "$root/materialized.json appeared meanwhile"
rm -f "$tmp"
rm -rf "$scratch"
trap - EXIT INT TERM
