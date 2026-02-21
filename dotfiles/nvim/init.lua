-- Neovim init.lua  
-- Bootstrap and load configuration

-- Load basic options first
require("config.options")
require("config.keymaps")

-- Load plugin configurations directly (no lazy.nvim needed)
require("plugins.treesitter")
require("plugins.telescope")
require("plugins.nvim-tree")
require("plugins.gitsigns")

-- Set colorscheme (catppuccin from Stylix)
vim.cmd.colorscheme("catppuccin")
