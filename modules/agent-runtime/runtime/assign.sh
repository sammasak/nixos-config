# agent-runtime-assign: freeze a template's sources for one run, on the
# assigning host, before anything executes. A locked source copies its lock; an
# assignment-resolved one takes its commit from a devenv-platform prepare:plan
# document and is prefetched into the store. Every source gets a GC root under
# OUT/gcroots, which materialize uses as its anchor. OUT is locked for the run.
USAGE='agent-runtime-assign --template MANIFEST --run ID --out DIR [--plan PLAN.json]...'
template='' run='' out='' plans=()
while [ $# -gt 0 ]; do
  case $1 in
    --template) [ $# -ge 2 ] || usage; template=$2; shift 2 ;;
    --run) [ $# -ge 2 ] || usage; run=$2; shift 2 ;;
    --out) [ $# -ge 2 ] || usage; out=$2; shift 2 ;;
    --plan) [ $# -ge 2 ] || usage; plans+=("$2"); shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$template" ] && [ -n "$run" ] && [ -n "$out" ] || usage
[[ $run =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || fail usage "run id must be a DNS label: $run"
[ -f "$template" ] || fail usage "template manifest not found: $template"
jq -e '
  .kind == "agent-runtime-template" and .schemaVersion == 1 and (.sources | type == "object")
  and ([.sources | to_entries[] | .value as $s
        | (.key | test("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$"))
        and ($s.github | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_][A-Za-z0-9._-]*$"))
        and (($s.access // "public") | IN("public", "private"))
        and (($s.access // "public") == "public" or $s.resolve == "assignment")
        and (($s.resolve == "lock" and ($s.locked.storePath | type == "string"))
             or ($s.resolve == "assignment" and $s.locked == null and ($s.ref.value | type == "string")))] | all)
' "$template" >/dev/null 2>&1 || fail usage "$template is not a well-formed agent-runtime-template (schemaVersion 1)"
mkdir -p "$out"
exec 9>"$out/.lock"
flock -n 9 || fail state "$out is being assigned by another process"
[ -e "$out/run.json" ] && fail state "$out/run.json exists; a run is assigned once"
# the token is required before any fetch, for every private source
if jq -e '[.sources[] | select((.access // "public") == "private")] | length > 0' "$template" >/dev/null; then
  [ -n "${GH_TOKEN:-}" ] || fail credential "a private source is resolved at assignment: GH_TOKEN is required to prefetch it (never stored)"
  [[ $GH_TOKEN =~ ^[A-Za-z0-9_]+$ ]] || fail credential "GH_TOKEN has an unexpected shape"
fi

for p in "${plans[@]}"; do
  jq -e '.schema_version == 1 and (.source.repo | type == "string") and (.source.ref | type == "string")
         and (.source.sha | test("^[0-9a-f]{40}$")) and .source.subproject == "."' "$p" >/dev/null 2>&1 \
    || fail plan "$p is not a prepare:plan for a whole repository (schema_version 1, source.repo/ref/sha, subproject \".\")"
done
planned='[]'
[ ${#plans[@]} -eq 0 ] || planned=$(jq -sc 'map(.source)' "${plans[@]}")

# a leftover of a killed assignment: no run.json, so nothing refers to these roots
rm -rf "$out/gcroots" "$out"/.gcroots.* "$out"/.run.*
staging=$(mktemp -d "$out/.gcroots.XXXXXX")
tmp=$(mktemp "$out/.run.XXXXXX")
trap 'rm -rf "$staging" "$tmp"' EXIT

sources='{}'
names=$(jq -r '.sources | keys[]' "$template")
for name in $names; do
  src=$(jq -c --arg n "$name" '.sources[$n]' "$template")
  if [[ $(jq -r .resolve <<<"$src") == lock ]]; then
    resolved=$(jq -c '.locked + {by: "lock"}' <<<"$src")
  else
    repo=$(jq -r .github <<<"$src")
    ref=$(jq -r .ref.value <<<"$src")
    shas=$(jq -r --arg repo "${repo,,}" --arg ref "$ref" \
      '[.[] | select((.repo | ascii_downcase) == $repo and .ref == $ref) | .sha] | unique | join(" ")' <<<"$planned")
    [ -n "$shas" ] || fail plan "no prepare:plan given for $repo@$ref (resolve = assignment)"
    [[ $shas != *" "* ]] || fail plan "the plans disagree on $repo@$ref: $shas"
    config=${NIX_CONFIG:-}
    [[ $(jq -r '.access // "public"' <<<"$src") != private ]] \
      || config="${config:+$config$'\n'}access-tokens = github.com=$GH_TOKEN"
    NIX_CONFIG=$config run_capture github "prefetch of $repo@$shas failed" nix_cmd flake prefetch --json "github:$repo/$shas"
    resolved=$(jq -ec --arg sha "$shas" \
      'select((.hash | type == "string") and (.storePath | type == "string")) | {rev: $sha, narHash: .hash, storePath, by: "plan"}' \
      <<<"$captured") || fail github "prefetch of $repo@$shas returned no hash or store path"
  fi
  store_path=$(jq -r .storePath <<<"$resolved")
  run_capture store "$name: cannot root $store_path (absent from the store?)" \
    nix_cmd build --out-link "$staging/$name" "$store_path"
  sources=$(jq -c --arg n "$name" --argjson s "$src" --argjson r "$resolved" \
    '.[$n] = ($s | del(.locked) | . + {resolved: $r})' <<<"$sources")
done

body=$(jq -nc --arg run "$run" --argjson sources "$sources" --slurpfile t "$template" \
  '{run: {id: $run}, template: {name: $t[0].template.name, digests: $t[0].digests},
    workspace: $t[0].filesystem.workspace, sources: $sources}')
digest=$(jq -cS . <<<"$body" | sha256sum | cut -d' ' -f1)
jq --arg at "$(now)" --arg digest "$digest" \
  '{schemaVersion: 1, kind: "agent-runtime-run"} + . + {run: (.run + {assignedAt: $at}), digests: {run: $digest}}' \
  <<<"$body" >"$tmp"
mv "$staging" "$out/gcroots"
ln "$tmp" "$out/run.json" || fail state "cannot publish $out/run.json"
