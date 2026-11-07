# shellcheck shell=bash
# agent-runtime-promote: the trusted host's promotion of a VERIFIED export bundle (#169 acceptance 3).
# It runs agent-runtime-verify first and refuses an unverified or failing bundle, then applies the
# verified patch onto an operator-supplied clean git checkout, confirms the staged tree equals the tree
# the verifier reproduced, commits it on a new branch, and prints a promotion record (bundle digest,
# base rev, the new commit sha, changedPaths). It never fetches, pushes, or touches a GitHub token --
# the coordinator pushes the branch and opens the PR with the host's own gh. "Promotes only reviewed
# artifacts; record SHA/digest" (the issue), as one exit-gated command instead of a manual git sequence.
USAGE='agent-runtime-promote --bundle DIR --template MANIFEST --into WORKTREE --branch NAME [--source NAME] [--max-patch-bytes N]'
bundle='' template='' into='' branch='' source='' max=1048576
while [ $# -gt 0 ]; do
  case $1 in
    --bundle) [ $# -ge 2 ] || usage; bundle=$2; shift 2 ;;
    --template) [ $# -ge 2 ] || usage; template=$2; shift 2 ;;
    --into) [ $# -ge 2 ] || usage; into=$2; shift 2 ;;
    --branch) [ $# -ge 2 ] || usage; branch=$2; shift 2 ;;
    --source) [ $# -ge 2 ] || usage; source=$2; shift 2 ;;
    --max-patch-bytes) [ $# -ge 2 ] || usage; max=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$bundle" ] && [ -n "$template" ] && [ -n "$into" ] && [ -n "$branch" ] && [[ $max =~ ^[1-9][0-9]*$ ]] || usage

# 1. verify first: promote only a reviewed, reproducible artifact. --require-change refuses a no-op.
verr=$(mktemp)
v=$(agent-runtime-verify --bundle "$bundle" --template "$template" --max-patch-bytes "$max" --require-change 2>"$verr") && vrc=0 || vrc=$?
if [ "$vrc" -ne 0 ]; then cat "$verr" >&2; rm -f "$verr"; exit "$vrc"; fi
rm -f "$verr"

# 2. choose the changed source (the bundle usually carries one repo)
names=$(jq -r '.sources | keys[]' <<<"$v")
if [ -z "$source" ]; then
  [ "$(printf '%s\n' "$names" | grep -c .)" -eq 1 ] || fail usage "the bundle changed multiple sources ($(echo "$names" | tr '\n' ' ')); pass --source NAME"
  source=$names
fi
rec=$(jq -ce --arg n "$source" '.sources[$n] // empty' <<<"$v") || fail usage "no verified source $source in the bundle (have: $(echo "$names" | tr '\n' ' '))"
tree=$(jq -r .tree <<<"$rec"); rev=$(jq -r '.base.rev // ""' <<<"$rec")
patch="$bundle/sources/$source.patch"
[ -f "$patch" ] || fail export "no patch for $source in the bundle"

# 3. the operator's checkout: a clean git worktree. The verified tree is the guarantee the content is
#    the pinned base; a HEAD rev other than the pinned rev is only noted.
git -C "$into" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail usage "$into is not a git worktree"
[ -z "$(git -C "$into" status --porcelain)" ] || fail usage "$into has uncommitted changes; promote onto a clean checkout at the pinned base"
head=$(git -C "$into" rev-parse HEAD 2>/dev/null || true)
if [ -z "$rev" ] || [ "$rev" = "$head" ]; then
  rev_note="at the pinned base ${rev:-$head}"
else
  rev_note="HEAD $head is not the pinned base rev $rev (the verified tree is still checked below)"
fi

# 4. branch, apply the verified patch, confirm the staged tree matches the verifier's, then commit
git -C "$into" checkout -q -b "$branch" || fail conflict "could not create branch $branch in $into (does it exist?)"
git -C "$into" apply --index --binary "$patch" 2>/dev/null || fail export "the verified patch did not apply to $into ($rev_note)"
staged=$(git -C "$into" write-tree)
[ "$staged" = "$tree" ] || fail export "the promoted tree $staged is not the verified tree $tree: $into is not the pinned base content"
bsha=$(sha256sum "$bundle/bundle.json" | cut -d' ' -f1)
task=$(jq -r '.task // ""' <<<"$v"); id=$(jq -r '.id // ""' <<<"$v")
msg=$(printf 'agent-runtime: promote %s (%s)\n\nVerified bundle %s applied to source %s (%s).\nchangedPaths: %s\nNo GitHub token entered the runtime; the trusted host pushes this branch.' \
  "$source" "$task" "$bsha" "$source" "$rev_note" "$(jq -rc .changedPaths <<<"$rec")")
git -C "$into" -c user.name=agent-runtime -c user.email=agent-runtime@localhost commit -q -m "$msg" \
  || fail conflict "could not commit the promotion in $into"
commit=$(git -C "$into" rev-parse HEAD)

jq -nc --arg b "$bsha" --arg t "$task" --arg id "$id" --arg s "$source" --arg br "$branch" --arg rev "$rev" \
  --arg c "$commit" --arg tree "$tree" --argjson rec "$rec" --arg at "$(now)" \
  '{kind: "agent-runtime-promoted", schemaVersion: 1, bundleSha256: $b, id: $id, task: $t, source: $s,
    branch: $br, baseRev: (if $rev == "" then null else $rev end), commit: $c, tree: $tree,
    changedPaths: $rec.changedPaths, pushed: false, promotedAt: $at,
    note: "push this branch with the trusted host gh and open the PR; no GitHub token entered the runtime"}'
