# shellcheck shell=bash
# agent-runtime-verify: the trusted host's check of an exported bundle (#169), before anyone reviews or
# promotes its patch. Read-only on the bundle; it never runs the patch's code. In order:
#   bundle.json and every file it lists, by sha256 (an interrupted or edited export fails here);
#   each source's patch against its record: digest, size cap, no oversized patch omitted at export;
#   the patch's paths: relative, inside the repository, never .git, exactly the recorded changedPaths;
#   the pinned base in this host's store, by narHash; the patch applied to the base tree reproduces the
#   exported tree id (a malformed or foreign patch does not apply).
# Prints {kind: "agent-runtime-verified", ...} on success; every refusal is one JSON error line.
USAGE='agent-runtime-verify --bundle DIR [--max-patch-bytes N] [--require-change]'
bundle='' max=1048576 require_change=0
while [ $# -gt 0 ]; do
  case $1 in
    --bundle) [ $# -ge 2 ] || usage; bundle=$2; shift 2 ;;
    --max-patch-bytes) [ $# -ge 2 ] || usage; max=$2; shift 2 ;;
    --require-change) require_change=1; shift ;;
    *) usage ;;
  esac
done
[ -n "$bundle" ] && [[ $max =~ ^[1-9][0-9]*$ ]] || usage
[ -f "$bundle/bundle.json" ] || fail export "$bundle has no bundle.json: the export did not finish"
jq -e '.kind == "agent-runtime-instance-export" and (.files | type == "array")' "$bundle/bundle.json" >/dev/null 2>&1 \
  || fail export "$bundle/bundle.json is not an agent-runtime export record"
while IFS=$'\t' read -r path sum; do
  case $path in /* | ../* | */../* | ..) fail export "bundle.json lists a path outside the bundle: $path" ;; esac
  [ -f "$bundle/$path" ] || fail export "$path is listed in bundle.json but missing: the export is incomplete"
  [ "$(sha256sum "$bundle/$path" | cut -d' ' -f1)" = "$sum" ] || fail export "$path does not match its sha256 in bundle.json"
done < <(jq -r '.files[] | [.path, .sha256] | @tsv' "$bundle/bundle.json")
omitted=$(jq -r '[.omittedPatches[]?.patch] | join(" ")' "$bundle/bundle.json")
[ -z "$omitted" ] || fail export "oversized patch omitted at export: $omitted; nothing to verify"
if [ -d "$bundle/sources" ] && [ ! -f "$bundle/sources/export.json" ]; then
  fail export "sources/export.json is missing: the source export was interrupted"
fi

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
git_scratch "$scratch/repo"
verified='{}' changed_total=0 base=''
for rec in "$bundle"/sources/*.json; do
  [ -e "$rec" ] || continue
  name=$(basename "$rec" .json)
  [ "$name" != export ] || continue
  patch=$bundle/sources/$(jq -r .patch "$rec")
  [ -f "$patch" ] || fail export "$name: its patch is missing"
  [ "$(sha256sum "$patch" | cut -d' ' -f1)" = "$(jq -r .patchSha256 "$rec")" ] || fail export "$name: the patch does not match its patchSha256"
  bytes=$(stat -c %s "$patch")
  [ "$bytes" -le "$max" ] || fail budget "$name: the patch is $bytes bytes, over the $max-byte cap"
  # the paths the patch would write, as git reads them (renames give both sides); an empty patch is an
  # unchanged source, which git apply would call malformed
  paths=''
  if [ -s "$patch" ]; then
    paths=$(git apply --numstat -z "$patch" 2>/dev/null | tr '\0' '\n' | awk -F'\t' 'NF >= 3 {print $3; next} NF == 1 && $1 != "" {print $1}') \
      || fail export "$name: the patch is malformed"
    [ -n "$paths" ] || fail export "$name: the patch is malformed (no file it applies to)"
  fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "/$p/" in
      //* | */../* | */./*) fail export "$name: the patch writes outside the repository: $p" ;;
      /.git/*) fail export "$name: the patch writes the repository's .git: $p" ;;
    esac
  done <<<"$paths"
  want=$(jq -c '.changedPaths | sort' "$rec")
  got=$(jq -Rsc 'split("\n") | map(select(length > 0)) | unique' <<<"$paths")
  [ "$got" = "$want" ] || fail export "$name: the patch touches $got, the record says $want"
  # the pinned base, from this host's store, by its recorded narHash
  store=$(jq -r .base.storePath "$rec")
  [ -d "$store" ] || fail source "$name: the pinned base $store is not in this host's store"
  nar=$(nix_cmd path-info --json "$store" 2>/dev/null | jq -r 'if type == "array" then .[0].narHash else .[].narHash end' 2>/dev/null || true)
  [ "$nar" = "$(jq -r .base.narHash "$rec")" ] || fail source "$name: $store has narHash ${nar:-unknown}, the record says $(jq -r .base.narHash "$rec")"
  tree_of base "$store"
  git read-tree "$base"
  if [ -s "$patch" ]; then
    git apply --cached --binary "$patch" 2>/dev/null || fail export "$name: the patch does not apply to the pinned base"
  fi
  result=$(git write-tree)
  [ "$result" = "$(jq -r .tree "$rec")" ] || fail export "$name: the patched base is tree $result, the export recorded $(jq -r .tree "$rec")"
  n=$(jq 'length' <<<"$want")
  changed_total=$((changed_total + n))
  verified=$(jq -c --arg n "$name" --slurpfile r "$rec" --arg tree "$result" --argjson b "$bytes" \
    '.[$n] = {base: $r[0].base, patchSha256: $r[0].patchSha256, patchBytes: $b, tree: $tree, changedPaths: $r[0].changedPaths}' <<<"$verified")
done
[ "$require_change" = 0 ] || [ "$changed_total" -gt 0 ] || fail export "no source changed: the run produced an empty patch"
jq -n --arg b "$(sha256sum "$bundle/bundle.json" | cut -d' ' -f1)" --slurpfile r "$bundle/bundle.json" --argjson s "$verified" --arg at "$(now)" \
  '{kind: "agent-runtime-verified", schemaVersion: 1, bundleSha256: $b, id: $r[0].id, task: $r[0].task, template: $r[0].template,
    outcome: $r[0].outcome, sources: $s, verifiedAt: $at}'
