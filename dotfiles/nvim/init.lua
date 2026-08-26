-- Neovim init.lua
-- Plugin configurations are handled inline by Nix module

-- Load basic options and keymaps
require("config.options")
require("config.keymaps")

-- Set colorscheme (catppuccin from Stylix)
vim.cmd.colorscheme("catppuccin")
