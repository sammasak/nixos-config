# shellcheck shell=bash
# repo-sweep [--apply] [--days N] [ROOT...]
#
# Reclaims space from git checkouts directly under ROOT (default: ~ and ~/wt)
# that nothing has touched for N days (default 14). Dry run unless --apply.
#
# In an idle checkout it deletes gitignored build caches (target/,
# node_modules/). It deletes the checkout itself only when the remote can
# recreate it exactly: no tracked or untracked changes, no other ignored
# files, no stash, every commit on a remote-tracking ref, and no other
# worktrees attached. Anything else is reported and left alone.

apply=0
days=14
while (($#)); do
  case $1 in
    --apply) apply=1 ;;
    --days) days=$2; shift ;;
    *) break ;;
  esac
  shift
done
roots=("$@")
((${#roots[@]})) || roots=("$HOME" "$HOME/wt")
# Home Manager activation wires git hooks into these by path.
protected=" nixos-config knowledge claude-code-skills homelab-gitops "
caches=(target node_modules)

act() {
  if ((apply)); then "$@"; else printf '  (dry run) %s\n' "$*"; fi
}

keep() {
  printf 'keep   %s: %s\n' "$1" "$2"
}

for root in "${roots[@]}"; do
  for dir in "$root"/*/; do
    dir=${dir%/}
    top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || continue
    [[ $top == "$(realpath "$dir")" ]] || continue
    [[ $protected == *" $(basename "$dir") "* ]] && continue
    if [[ -n $(find "$dir" -path "$dir/.git" -prune -o -newermt "$days days ago" -print -quit 2>/dev/null) ]]; then
      continue
    fi

    for cache in "${caches[@]}"; do
      if [[ -d $dir/$cache ]] && git -C "$dir" check-ignore -q "$cache"; then
        printf 'cache  %s/%s (%s)\n' "$dir" "$cache" "$(du -sh "$dir/$cache" | cut -f1)"
        act rm -rf "${dir:?}/$cache"
      fi
    done

    pattern=$(printf '|%s/' "${caches[@]}")
    leftover=$(git -C "$dir" status --porcelain --ignored | grep -vE "^!! (${pattern:1})$" | head -3 || true)
    if [[ -n $leftover ]]; then
      keep "$dir" "local files: $(tr '\n' ' ' <<<"$leftover")"
      continue
    fi
    if [[ -z $(git -C "$dir" remote) ]]; then
      keep "$dir" "no remote"
      continue
    fi

    common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir)
    if [[ -f $dir/.git ]]; then
      if [[ -n $(git -C "$dir" rev-list -n1 HEAD --not --remotes) ]]; then
        keep "$dir" "HEAD has commits on no remote"
        continue
      fi
      printf 'remove %s (worktree, %s)\n' "$dir" "$(du -sh "$dir" | cut -f1)"
      act git --git-dir="$common" worktree remove "$dir"
    else
      if [[ -n $(git -C "$dir" rev-list -n1 HEAD --branches --not --remotes) ]]; then
        keep "$dir" "commits on no remote"
      elif [[ -n $(git -C "$dir" stash list) ]]; then
        keep "$dir" "has a stash"
      elif (($(git -C "$dir" worktree list --porcelain | grep -c '^worktree ') > 1)); then
        keep "$dir" "other worktrees attached"
      else
        printf 'remove %s (clone, %s)\n' "$dir" "$(du -sh "$dir" | cut -f1)"
        act rm -rf "${dir:?}"
      fi
    fi
  done
done
