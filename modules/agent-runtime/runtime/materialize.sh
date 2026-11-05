# agent-runtime-materialize: instantiate a run's sources under one instance root,
# without network. The template manifest is the trust anchor: the run must
# describe exactly its sources. A read-only source is its verified store path; a
# writable one is copied into ROOT/workspace/<name>. A failed run leaves nothing
# under ROOT. Writes ROOT/materialized.json and ROOT/export-pending.
USAGE='agent-runtime-materialize --run RUN.json --template MANIFEST --root DIR'
run='' template='' root=''
while [ $# -gt 0 ]; do
  case $1 in
    --run) [ $# -ge 2 ] || usage; run=$2; shift 2 ;;
    --template) [ $# -ge 2 ] || usage; template=$2; shift 2 ;;
    --root) [ $# -ge 2 ] || usage; root=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$run" ] && [ -n "$template" ] && [ -n "$root" ] || usage
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
        and ($r.resolved.rev | test("^[0-9a-f]{40}$"))
        and ($r.resolved.narHash | test("^sha256-[A-Za-z0-9+/]{43}=$"))] | all)
' "$run" >/dev/null 2>&1 \
  || fail source "$run does not describe the sources of $template (digests, names, paths, modes or locks differ)"
[ -e "$root/materialized.json" ] && fail state "$root is already materialized"
[ -e "$root/workspace" ] && fail state "$root/workspace exists; refusing to touch state this run did not create"

mkdir -p "$root"
root=$(realpath "$root")
mkdir "$root/workspace"
trap 'rm -rf "$root/workspace"' EXIT

record='{}'
while IFS= read -r name; do
  src=$(jq -c --arg n "$name" '.sources[$n]' "$run")
  store_path=$(jq -r .resolved.storePath <<<"$src")
  want=$(jq -r .resolved.narHash <<<"$src")
  [[ $store_path =~ ^/nix/store/[a-z0-9]{32}-[A-Za-z0-9+._?=-]+$ && -d $store_path ]] \
    && [[ $(realpath -e "$store_path" 2>/dev/null) == "$store_path" ]] \
    || fail store "$name: $store_path is not a present top-level store path (a build or closure failure, not a GitHub one)"
  err=$(mktemp)
  have=$(nix --extra-experimental-features nix-command hash path "$store_path" 2>"$err") \
    || fail store "$name: cannot hash $store_path: $(tail -c 200 "$err" | tr '\n' ' ')"
  rm -f "$err"
  [[ $have == "$want" ]] || fail store "$name: $store_path has NAR hash $have, the run manifest says $want"
  while IFS= read -r link; do
    target=$(realpath -m "$link")
    case $target in "$store_path" | "$store_path"/*) ;; *) fail source "$name: symlink $link escapes the source tree ($target)" ;; esac
  done < <(find "$store_path" -type l)
  if [[ $(jq -r .writable <<<"$src") == true ]]; then
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
done < <(jq -r '.sources | keys[]' "$run")

jq -r 'to_entries[] | select(.value.mode == "rw") | .key' <<<"$record" >"$root/export-pending"
tmp=$(mktemp "$root/.materialized.XXXXXX")
jq -n --slurpfile r "$run" --argjson s "$record" \
  '{schemaVersion: 1, kind: "agent-runtime-instance", run: $r[0].run, template: $r[0].template,
    workspace: $r[0].workspace, sources: $s}' >"$tmp"
mv "$tmp" "$root/materialized.json"
trap - EXIT
