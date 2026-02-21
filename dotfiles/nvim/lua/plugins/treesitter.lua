-- Treesitter configuration for syntax highlighting
return {
  "nvim-treesitter/nvim-treesitter",
  event = { "BufReadPost", "BufNewFile" },
  config = function()
    require("nvim-treesitter.configs").setup({
      -- Grammars installed via Nix (withAllGrammars)
      auto_install = false,

      -- Enable syntax highlighting
      highlight = {
        enable = true,
        additional_vim_regex_highlighting = false,
      },

      -- Enable smart indentation
      indent = {
        enable = true,
      },

      -- Enable incremental selection
      incremental_selection = {
        enable = true,
        keymaps = {
          init_selection = "<CR>",
          node_incremental = "<CR>",
          scope_incremental = "<S-CR>",
          node_decremental = "<BS>",
        },
      },
    })
  end,
}
