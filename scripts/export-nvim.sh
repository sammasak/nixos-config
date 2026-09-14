#!/usr/bin/env bash
# Mirror dotfiles/nvim into the standalone public repo the work machine clones.
#
# nixos-config stays the source of truth; this pushes the subdirectory's own
# history to github.com/sammasak/nvim-config via `git subtree split`. The nvim
# config carries no secrets, so the mirror is safe to be public.
#
# One-time: create the empty public repo, e.g.
#   gh repo create sammasak/nvim-config --public --disable-issues
set -euo pipefail

remote_url="${1:-git@github.com:sammasak/nvim-config.git}"
prefix="dotfiles/nvim"
tmp_branch="_nvim_export"

root="$(git rev-parse --show-toplevel)"
cd "$root"

if [ -n "$(git status --porcelain)" ]; then
  echo "export-nvim: working tree is dirty; commit dotfiles/nvim first so the split matches HEAD." >&2
  exit 1
fi

git branch -D "$tmp_branch" 2>/dev/null || true
git subtree split --prefix="$prefix" -b "$tmp_branch"
git push --force "$remote_url" "$tmp_branch:main"
git branch -D "$tmp_branch"

echo "export-nvim: pushed $prefix -> $remote_url (main)."
