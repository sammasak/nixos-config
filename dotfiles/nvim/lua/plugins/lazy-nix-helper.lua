-- lazy-nix-helper: Bridge between Nix-installed plugins and lazy.nvim
local lazy_nix_helper = require("lazy-nix-helper")

-- Setup lazy.nvim with Nix-installed plugins
require("lazy").setup({
  -- Plugin configurations
  { import = "plugins.treesitter" },
  { import = "plugins.telescope" },
  { import = "plugins.nvim-tree" },
  { import = "plugins.gitsigns" },
}, {
  -- Use Nix-installed plugins
  performance = {
    reset_packpath = false,
    rtp = {
      reset = false,
    },
  },
  dev = {
    path = lazy_nix_helper.pluginPath,
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
