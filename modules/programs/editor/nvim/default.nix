# Neovim with lazy.nvim + lazy-nix-helper
{ pkgs, ... }:
{
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;

    plugins = with pkgs.vimPlugins; [
      # Plugin manager
      lazy-nvim

      # Treesitter for syntax highlighting
      nvim-treesitter.withAllGrammars

      # Fuzzy finder
      telescope-nvim
      telescope-fzf-native-nvim
      plenary-nvim

      # File explorer
      nvim-tree-lua
      nvim-web-devicons

      # Git integration
      gitsigns-nvim

      # Catppuccin theme (already available via Stylix)
      catppuccin-nvim
    ];

    extraPackages = with pkgs; [
      # Treesitter dependencies
      gcc
      tree-sitter

      # Telescope dependencies
      ripgrep
      fd
    ];
  };

  # Symlink Neovim config from dotfiles
  xdg.configFile."nvim".source = ../../../../dotfiles/nvim;
}
