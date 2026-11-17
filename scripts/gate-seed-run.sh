#!/usr/bin/env bash
# The seeded real run of #502: one host's configuration changed (an /etc file only it has), then this checkout's
# nixos-flake-check on that tree, as the gate runs it. Passes when every check that compiles or is deferred belongs to
# the seeded node (deploy-activate-<node>, deploy-schema-<node>). Judged against a dry run of the unseeded tree first,
# so a check this store has not built yet for HEAD does not count: only what the seed changed does.
# usage: scripts/gate-seed-run.sh NODE [--dry]
#   --dry  decide and print, build nothing (NIXOS_FLAKE_CHECK_DRY): what acer would do, without compiling anything
set -euo pipefail
node=${1:?usage: gate-seed-run.sh NODE [--dry]}
dry=${2:-}
repo=$(git rev-parse --show-toplevel)
shopt -s nullglob
dirs=("$repo"/hosts/"$node"*)
[ ${#dirs[@]} -eq 1 ] || { echo "gate-seed-run: want one hosts/$node* directory, found ${#dirs[@]}" >&2; exit 2; }
dir=hosts/${dirs[0]##*/}
lock=/run/work-locks/heavy-work.lock
[ -d /run/work-locks ] || lock=/tmp/$(uname -n)-heavy-work.lock
tree=$(mktemp -d)
trap 'git -C "$repo" worktree remove --force "$tree"' EXIT
git -C "$repo" worktree add --quiet --detach "$tree" HEAD
cd "$tree"
avail=$(awk '/^MemAvailable:/ { print int($2 / 1048576) }' /proc/meminfo)
echo "gate-seed-run: $(uname -n), MemAvailable ${avail} GiB, lock $lock, seed $dir, ${dry:+dry, }HEAD $(git rev-parse --short HEAD)"
# one line per check: name, the derivations its build would compile, and "deferred" if left to its own host
run() {
  NIXOS_FLAKE_CHECK_DRY=$1 NIXOS_QA_TIMES=$tree/times flock -o "$lock" devenv tasks run nixos:flake-check >"$2" 2>&1 \
    || { tail -n 30 "$2"; echo "gate-seed-run: the flake check failed ($2)" >&2; exit 1; }
  { sed -n 's/^.*nixos-flake-check: build \(checks\.[^ ]*\) (compiles \([0-9]*\))$/\1 \2/p' "$2"
    sed -n 's/^.*nixos-flake-check: deferred \(checks\.[^ ]*\) to [^(]*(compiles \([0-9]*\)).*/\1 \2 deferred/p' "$2"; } | sort
}
run 1 "$tree/before.log" >"$tree/before"
printf '{ environment.etc."gate-seed".text = "%s"; }\n' "$(date +%s)" >"$dir/gate-seed.nix"
sed -i '0,/imports = \[/s//imports = [ .\/gate-seed.nix/' "$dir/configuration.nix"
grep -q 'gate-seed.nix' "$dir/configuration.nix" || { echo "gate-seed-run: no imports list in $dir/configuration.nix" >&2; exit 2; }
git add -A
run "${dry:+1}" "$tree/after.log" >"$tree/after"
changed=$(comm -13 "$tree/before" "$tree/after")
echo "changed by the seed (check, derivations it compiles or deferred):"
awk '{ print "  " $0 }' <<<"${changed:-none}"
grep 'deferred to' "$tree/after.log" | sed 's/^.*nixos-flake-check: /  /' || true
others=$(awk 'NF { print $1 }' <<<"$changed" | grep -vE "\.deploy-(activate|schema)-$node$" || true)
if [ -n "$others" ]; then
  echo "gate-seed-run: FAIL: the seed changed checks of other nodes: $(tr '\n' ' ' <<<"$others")" >&2
  exit 1
fi
[ -n "$changed" ] || { echo "gate-seed-run: FAIL: the seed changed no check; was it applied?" >&2; exit 1; }
echo "gate-seed-run: PASS: only $node's checks changed"
