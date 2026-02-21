-- Neovim init.lua
-- Bootstrap and load configuration

-- Load basic options first
require("config.options")
require("config.keymaps")

-- Initialize lazy.nvim with lazy-nix-helper
require("plugins.lazy-nix-helper")
