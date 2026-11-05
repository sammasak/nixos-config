# agent-runtime-materialize: instantiate a run's sources under one instance root,
# without network. A read-only source binds its store path; a writable one is
# copied into ROOT/workspace/<name>. Every store path's NAR hash is verified;
# traversal and symlink escapes are refused and a failed run leaves nothing
# behind. Writes ROOT/binds (mode, source, path), ROOT/materialized.json and the
# ROOT/export-pending marker. Exit 2 usage, 4 store, 6 path/source, 1 state.
usage() { echo 'usage: agent-runtime-materialize --run RUN.json --root DIR' >&2; exit 2; }
fail() { jq -nc --arg class "$1" --arg message "$2" '{error:{class:$class,message:$message}}' >&2; exit "$3"; }

run='' root=''
while [ $# -gt 0 ]; do
  case $1 in
    --run) run=${2:-}; shift 2 ;;
    --root) root=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$run" ] && [ -n "$root" ] || usage
[ -f "$run" ] || fail usage "run manifest not found: $run" 2
jq -e '.kind == "agent-runtime-run" and .schemaVersion == 1' "$run" >/dev/null 2>&1 \
  || fail usage "$run is not an agent-runtime-run, schemaVersion 1" 2
[ -e "$root/materialized.json" ] && fail state "$root is already materialized" 1

ws=$(jq -r .workspace "$run")
mkdir -p "$root/workspace"
root=$(realpath "$root")
binds=$(mktemp)
abort() { rm -rf "$root/workspace" "$binds"; fail "$@"; }

record='{}'
while IFS= read -r name; do
  src=$(jq -c --arg n "$name" '.sources[$n]' "$run")
  path=$(jq -r .path <<<"$src")
  sp=$(jq -r .resolved.storePath <<<"$src")
  nar=$(jq -r .resolved.narHash <<<"$src")
  [[ $name =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || abort path "$name: source names are DNS labels" 6
  case $path in "$ws"/*) ;; *) abort path "$name: $path is not under $ws" 6 ;; esac
  case "$path/" in *'/../'* | *'/./'* | *'//'*) abort path "$name: $path is not normalized" 6 ;; esac
  [[ $sp == /nix/store/* ]] && [ -d "$sp" ] \
    || abort store "$name: store path missing: $sp (a build or closure failure, not a GitHub one)" 4
  have=$(nix --extra-experimental-features nix-command hash path "$sp" 2>/dev/null) || abort store "$name: cannot hash $sp" 4
  [ "$have" = "$nar" ] || abort store "$name: $sp has NAR hash $have, the run manifest says $nar" 4
  while IFS= read -r link; do
    target=$(realpath -m "$link")
    case $target in "$sp"/*) ;; *) abort source "$name: symlink $link escapes the source tree ($target)" 6 ;; esac
  done < <(find "$sp" -type l)
  if [ "$(jq -r .writable <<<"$src")" = true ]; then
    dest=$root/workspace/$name
    mkdir "$dest"
    cp -a "$sp/." "$dest/"
    chmod -R u+w "$dest"
    mode=rw
    bytes=$(du -sb "$dest" | cut -f1)
  else
    dest=$sp
    mode=ro
    bytes=0
  fi
  printf '%s\t%s\t%s\n' "$mode" "$dest" "$path" >>"$binds"
  record=$(jq -c --arg n "$name" --arg m "$mode" --arg d "$dest" --arg p "$path" --argjson b "$bytes" --argjson s "$src" \
    '.[$n] = {mode: $m, source: $d, path: $p, bytes: $b} + ($s.resolved | {rev, narHash, storePath})' <<<"$record")
done < <(jq -r '.sources | keys[]' "$run")

mv "$binds" "$root/binds"
jq -r 'to_entries[] | select(.value.mode == "rw") | .key' <<<"$record" >"$root/export-pending"
jq -n --slurpfile r "$run" --argjson s "$record" \
  '{schemaVersion: 1, kind: "agent-runtime-instance", run: $r[0].run, template: $r[0].template,
    workspace: $r[0].workspace, sources: $s}' >"$root/materialized.json"
