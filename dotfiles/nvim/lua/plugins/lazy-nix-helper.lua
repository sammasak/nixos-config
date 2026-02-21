-- lazy.nvim setup for Nix-installed plugins
-- No lazy-nix-helper needed - we configure lazy to work with Nix directly

-- Setup lazy.nvim with Nix-installed plugins
require("lazy").setup({
  -- Plugin configurations
  { import = "plugins.treesitter" },
  { import = "plugins.telescope" },
  { import = "plugins.nvim-tree" },
  { import = "plugins.gitsigns" },
}, {
  -- Use Nix-installed plugins (don't reset packpath or runtimepath)
  performance = {
    reset_packpath = false,
    rtp = {
      reset = false,
    },
  },
  install = {
    -- Don't install plugins, they're from Nix
    missing = false,
  },
  ui = {
    border = "rounded",
  },
})

-- Set colorscheme (catppuccin from Stylix)
vim.cmd.colorscheme("catppuccin")
