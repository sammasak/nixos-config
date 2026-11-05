# agent-runtime-assign: freeze a template's sources for one run, before anything
# executes. A locked source copies its lock; an assignment-resolved one takes its
# commit from a devenv-platform `prepare:plan` document and is prefetched into
# the store here, on the assigning host. Exit 2 usage, 3 resolution (no plan),
# 4 nix prefetch, 5 credential, 1 state.
usage() { echo 'usage: agent-runtime-assign --template MANIFEST --run ID --out DIR [--plan PLAN.json]...' >&2; exit 2; }
fail() { jq -nc --arg class "$1" --arg message "$2" '{error:{class:$class,message:$message}}' >&2; exit "$3"; }

template='' run='' out='' plans=()
while [ $# -gt 0 ]; do
  case $1 in
    --template) template=${2:-}; shift 2 ;;
    --run) run=${2:-}; shift 2 ;;
    --out) out=${2:-}; shift 2 ;;
    --plan) plans+=("${2:-}"); shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$template" ] && [ -n "$run" ] && [ -n "$out" ] || usage
[[ $run =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || fail usage "run id must be a DNS label: $run" 2
[ -f "$template" ] || fail usage "template manifest not found: $template" 2
jq -e '.kind == "agent-runtime-template" and .schemaVersion == 1' "$template" >/dev/null 2>&1 \
  || fail usage "$template is not an agent-runtime-template, schemaVersion 1" 2
[ -e "$out/run.json" ] && fail state "$out/run.json exists; a run is assigned once" 1

# the plans by repository and requested ref (devenv-platform prepare:plan, schema_version 1)
planned='[]'
for p in "${plans[@]}"; do
  jq -e '.schema_version == 1 and (.source.repo | type == "string") and (.source.ref | type == "string")
         and (.source.sha | test("^[0-9a-f]{40}$"))' "$p" >/dev/null 2>&1 \
    || fail github "$p is not a prepare:plan (schema_version 1 with source.repo, source.ref, source.sha)" 3
  planned=$(jq -c --slurpfile p "$p" '. + [$p[0].source]' <<<"$planned")
done

# sets $prefetched; the token reaches nix through its environment only
prefetch() {
  local repo=$1 sha=$2 access=$3 err rc=0 message
  err=$(mktemp)
  if [ "$access" = private ]; then
    [ -n "${GH_TOKEN:-}" ] || fail credential "$repo is private: GH_TOKEN is required to prefetch it (never stored)" 5
    prefetched=$(NIX_CONFIG="access-tokens = github.com=$GH_TOKEN" \
      nix --extra-experimental-features 'nix-command flakes' flake prefetch --json "github:$repo/$sha" 2>"$err") || rc=$?
  else
    prefetched=$(nix --extra-experimental-features 'nix-command flakes' flake prefetch --json "github:$repo/$sha" 2>"$err") || rc=$?
  fi
  message=$(tail -c 400 "$err" | tr '\n' ' ')
  rm -f "$err"
  [ -z "${GH_TOKEN:-}" ] || message=${message//"$GH_TOKEN"/<redacted>}
  [ "$rc" -eq 0 ] || fail nix "prefetch of $repo@$sha failed: $message" 4
  prefetched=$(jq -ec --arg sha "$sha" '{rev: $sha, narHash: .hash, storePath: .storePath} | select(.narHash and .storePath)' <<<"$prefetched") \
    || fail nix "prefetch of $repo@$sha returned no hash or storePath" 4
}

sources='{}'
while IFS= read -r name; do
  src=$(jq -c --arg n "$name" '.sources[$n]' "$template")
  if [ "$(jq -r .resolve <<<"$src")" = lock ]; then
    resolved=$(jq -c '.locked + {by: "lock"}' <<<"$src")
  else
    repo=$(jq -r .github <<<"$src")
    ref=$(jq -r .ref.value <<<"$src")
    sha=$(jq -r --arg r "$repo" --arg ref "$ref" \
      'map(select((.repo | ascii_downcase) == ($r | ascii_downcase) and .ref == $ref)) | .[0].sha // empty' <<<"$planned")
    [ -n "$sha" ] || fail github "no prepare:plan given for $repo@$ref (resolve = assignment)" 3
    prefetch "$repo" "$sha" "$(jq -r '.access // "public"' <<<"$src")"
    resolved=$(jq -c '. + {by: "plan"}' <<<"$prefetched")
  fi
  sources=$(jq -c --arg n "$name" --argjson s "$src" --argjson r "$resolved" \
    '.[$n] = ($s | del(.locked) | . + {resolved: $r})' <<<"$sources")
done < <(jq -r '.sources | keys[]' "$template")

mkdir -p "$out"
tmp=$(mktemp "$out/.run.XXXXXX")
jq -n --arg run "$run" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg digest "$(jq -cS . <<<"$sources" | sha256sum | cut -d' ' -f1)" \
  --argjson sources "$sources" --slurpfile t "$template" '
  { schemaVersion: 1, kind: "agent-runtime-run",
    run: { id: $run, assignedAt: $at },
    template: { name: $t[0].template.name, digests: $t[0].digests },
    workspace: $t[0].filesystem.workspace,
    sources: $sources,
    digests: { run: $digest } }' >"$tmp"
mv "$tmp" "$out/run.json"
