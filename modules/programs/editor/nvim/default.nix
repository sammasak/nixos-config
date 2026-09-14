# LazyVim owns plugins (pinned by dotfiles/nvim/lazy-lock.json); Nix supplies
# native deps plus only the non-project-versioned language servers — every
# project server (rust-analyzer, vtsls, svelte) must come from its repo
# devshell via PATH.
{ pkgs, config, ... }:
let
  repoRoot = "/home/lukas/nixos-config";
  # Mason-off DAP adapter; self-contained (rpath), rustaceanvim finds it on PATH.
  codelldb = pkgs.writeShellScriptBin "codelldb" ''
    exec ${pkgs.vscode-extensions.vadimcn.vscode-lldb}/share/vscode/extensions/vadimcn.vscode-lldb/adapter/codelldb "$@"
  '';
  pythonDebug = pkgs.python3.withPackages (ps: [ ps.debugpy ]);
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
      basedpyright
      ruff
      nodejs
      markdownlint-cli2
      codelldb
    ];
    # HM owns init.lua; a whole-directory nvim symlink would collide with it.
    initLua = ''require("config.lazy")'';
  };

  # Stylix's base16 target injects a broken require("mini.base16") into init.lua
  # (errors on every launch); LazyVim owns the catppuccin colours instead.
  stylix.targets.neovim.enable = false;

  # Nix-provided debugpy interpreter for the live Lua config (Mason is off).
  xdg.configFile."nvim/nix.lua".text = ''
    return {
      debugpy_python = "${pythonDebug}/bin/python",
    }
  '';

  # Out-of-store symlinks: Lua edits and lock bumps apply without a rebuild.
  # The lock is symlinked (not just repo-resident) because lazy.lua now resolves
  # it at stdpath("config") so the same config works as a standalone clone.
  xdg.configFile."nvim/lua".source = config.lib.file.mkOutOfStoreSymlink "${repoRoot}/dotfiles/nvim/lua";
  xdg.configFile."nvim/lazy-lock.json".source = config.lib.file.mkOutOfStoreSymlink "${repoRoot}/dotfiles/nvim/lazy-lock.json";
}
