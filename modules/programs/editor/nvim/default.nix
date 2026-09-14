# LazyVim owns plugins (pinned by dotfiles/nvim/lazy-lock.json); Nix supplies
# native deps plus only the non-project-versioned language servers — every
# project server (rust-analyzer, vtsls, svelte) must come from its repo
# devshell via PATH.
{ pkgs, config, ... }:
let
  repoRoot = "/home/lukas/nixos-config";
in
{
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    withRuby = false;
    withPython3 = false;
    extraPackages = with pkgs; [
      gcc
      gnumake
      unzip
      ripgrep
      fd
      lua-language-server
      nil
      marksman
      # Mason is off on NixOS (lua/plugins/lsp.lua), so LazyVim's
      # ensure_installed formatters must be satisfied here or they silently fail.
      stylua
      shfmt
    ];
    # HM owns init.lua; a whole-directory nvim symlink would collide with it.
    initLua = ''require("config.lazy")'';
  };

  # Out-of-store symlinks: Lua edits and lock bumps apply without a rebuild.
  # The lock is symlinked (not just repo-resident) because lazy.lua now resolves
  # it at stdpath("config") so the same config works as a standalone clone.
  xdg.configFile."nvim/lua".source = config.lib.file.mkOutOfStoreSymlink "${repoRoot}/dotfiles/nvim/lua";
  xdg.configFile."nvim/lazy-lock.json".source = config.lib.file.mkOutOfStoreSymlink "${repoRoot}/dotfiles/nvim/lazy-lock.json";
}
