#!/usr/bin/env bash
# Bring a NON-NIX machine (e.g. the work laptop) up to the same nvim setup as
# home, with no root required. Idempotent: safe to re-run.
#
#   Installs mise (tool version manager), uses it to provide neovim + the CLI
#   deps nvim expects, wires mise + direnv into your shell, and links this repo
#   to ~/.config/nvim. LazyVim then bootstraps itself on first launch and
#   installs plugins pinned by lazy-lock.json.
#
# On NixOS this script is unnecessary — Home Manager provides neovim and deps,
# and Mason auto-disables. See README.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/nvim"

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

# 1. mise — user-local tool manager, the no-nix devshell substitute.
if ! command -v mise >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/mise" ]; then
  log "Installing mise (user-local)"
  curl -fsSL https://mise.run | sh
fi
export PATH="$HOME/.local/bin:$PATH"
eval "$(mise activate bash)"

# 2. Tools nvim + this config expect. Pinned globally; projects still override
#    per-directory via their own mise.toml.
log "Installing global tools via mise (neovim, node, ripgrep, fd, direnv)"
mise use -g neovim@latest node@lts ripgrep fd direnv

# 3. Shell hooks — mise for tool PATH, direnv for per-project .envrc adoption.
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  [ -e "$rc" ] || continue
  shell="$(basename "$rc" | sed 's/^\.//; s/rc$//')" # bash | zsh
  grep -q 'mise activate' "$rc"  || echo "eval \"\$(mise activate $shell)\"" >> "$rc"
  grep -q 'direnv hook'   "$rc"  || echo "eval \"\$(direnv hook $shell)\""   >> "$rc"
done
if command -v fish >/dev/null 2>&1; then
  fish_conf="$HOME/.config/fish/config.fish"
  mkdir -p "$(dirname "$fish_conf")"; touch "$fish_conf"
  grep -q 'mise activate' "$fish_conf" || echo 'mise activate fish | source' >> "$fish_conf"
  grep -q 'direnv hook'   "$fish_conf" || echo 'direnv hook fish | source'   >> "$fish_conf"
fi

# 4. Link this repo as the nvim config. Refuse to clobber an unrelated config.
if [ -L "$config_dir" ]; then
  log "$config_dir already a symlink -> $(readlink "$config_dir")"
elif [ -e "$config_dir" ]; then
  log "WARNING: $config_dir exists and is not a symlink. Back it up and remove it, then re-run."
  exit 1
else
  log "Linking $repo_dir -> $config_dir"
  mkdir -p "$(dirname "$config_dir")"
  ln -s "$repo_dir" "$config_dir"
fi

log "Done. Open a new shell (or source your rc), then run: nvim"
log "Per project: copy .envrc.example -> .envrc (and mise.toml.example -> mise.toml), then 'direnv allow'."
