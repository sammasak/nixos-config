# agent-runtime-assign: freeze a template's sources for one run, on the
# assigning host, before anything executes. A locked source copies its lock; an
# assignment-resolved one takes its commit from a devenv-platform prepare:plan
# document and is prefetched into the store. Every source gets a GC root under
# OUT/gcroots so it survives until the run directory is removed.
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
        and ($s.access | IN("public", "private"))
        and (($s.resolve == "lock" and ($s.locked.storePath | type == "string"))
             or ($s.resolve == "assignment" and $s.locked == null))] | all)
' "$template" >/dev/null 2>&1 || fail usage "$template is not a well-formed agent-runtime-template (schemaVersion 1)"
[ -e "$out/run.json" ] && fail state "$out/run.json exists; a run is assigned once"
# fail closed before any fetch: the token is required for every private assignment-resolved source
if jq -e '[.sources[] | select(.access == "private" and .resolve == "assignment")] | length > 0' "$template" >/dev/null; then
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

nix_cmd() { nix --extra-experimental-features 'nix-command flakes' "$@"; }

# sets $prefetched; the token reaches nix through NIX_CONFIG and nothing else
prefetch() {
  local repo=$1 sha=$2 access=$3 err rc=0 message
  err=$(mktemp)
  if [[ $access == private ]]; then
    prefetched=$(NIX_CONFIG="${NIX_CONFIG:+$NIX_CONFIG$'\n'}access-tokens = github.com=$GH_TOKEN" \
      nix_cmd flake prefetch --json "github:$repo/$sha" 2>"$err") || rc=$?
  else
    prefetched=$(nix_cmd flake prefetch --json "github:$repo/$sha" 2>"$err") || rc=$?
  fi
  message=$(<"$err")
  rm -f "$err"
  [ -z "${GH_TOKEN:-}" ] || message=${message//"$GH_TOKEN"/<redacted>}
  message=$(tail -c 400 <<<"$message" | tr '\n' ' ')
  [ "$rc" -eq 0 ] || fail github "prefetch of $repo@$sha failed: $message"
  prefetched=$(jq -c --arg sha "$sha" '{rev: $sha, narHash: .hash, storePath}' <<<"$prefetched")
}

mkdir -p "$out/gcroots"
tmp=$(mktemp "$out/.run.XXXXXX")
trap 'rm -f "$tmp"' EXIT
sources='{}'
while IFS= read -r name; do
  src=$(jq -c --arg n "$name" '.sources[$n]' "$template")
  if [[ $(jq -r .resolve <<<"$src") == lock ]]; then
    resolved=$(jq -c '.locked + {by: "lock"}' <<<"$src")
  else
    repo=$(jq -r .github <<<"$src")
    ref=$(jq -r .ref.value <<<"$src")
    sha=$(jq -r --arg r "$repo" --arg ref "$ref" \
      'map(select((.repo | ascii_downcase) == ($r | ascii_downcase) and .ref == $ref)) | .[0].sha // empty' <<<"$planned")
    [ -n "$sha" ] || fail plan "no prepare:plan given for $repo@$ref (resolve = assignment)"
    prefetch "$repo" "$sha" "$(jq -r .access <<<"$src")"
    resolved=$(jq -c '. + {by: "plan"}' <<<"$prefetched")
  fi
  store_path=$(jq -r .storePath <<<"$resolved")
  err=$(mktemp)
  nix_cmd build --out-link "$out/gcroots/$name" "$store_path" >/dev/null 2>"$err" \
    || fail store "$name: cannot root $store_path (absent from the store?): $(tail -c 300 "$err" | tr '\n' ' ')"
  rm -f "$err"
  sources=$(jq -c --arg n "$name" --argjson s "$src" --argjson r "$resolved" \
    '.[$n] = ($s | del(.locked) | . + {resolved: $r})' <<<"$sources")
done < <(jq -r '.sources | keys[]' "$template")

body=$(jq -nc --arg run "$run" --argjson sources "$sources" --slurpfile t "$template" \
  '{run: {id: $run}, template: {name: $t[0].template.name, digests: $t[0].digests},
    workspace: $t[0].filesystem.workspace, sources: $sources}')
digest=$(jq -cS . <<<"$body" | sha256sum | cut -d' ' -f1)
jq --arg at "$(now)" --arg digest "$digest" \
  '{schemaVersion: 1, kind: "agent-runtime-run"} + . + {run: (.run + {assignedAt: $at}), digests: {run: $digest}}' \
  <<<"$body" >"$tmp"
ln "$tmp" "$out/run.json" || fail state "$out/run.json appeared meanwhile; a run is assigned once"
