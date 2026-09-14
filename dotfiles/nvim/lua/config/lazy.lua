-- Bootstrap lazy.nvim, then LazyVim with local overrides from lua/plugins/.
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })
  if vim.v.shell_error ~= 0 then
    vim.api.nvim_echo({
      { "Failed to clone lazy.nvim:\n", "ErrorMsg" },
      { out, "WarningMsg" },
      { "\nPress any key to exit..." },
    }, true, {})
    vim.fn.getchar()
    os.exit(1)
  end
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  spec = {
    { "LazyVim/LazyVim", import = "lazyvim.plugins" },
    -- Language extras attach servers by PATH lookup; the binaries come from
    -- each repo's devshell/direnv, with Mason as the fallback off-Nix.
    { import = "lazyvim.plugins.extras.lang.rust" },
    { import = "lazyvim.plugins.extras.lang.python" },
    { import = "lazyvim.plugins.extras.lang.markdown" },
    { import = "lazyvim.plugins.extras.lang.typescript" },
    { import = "lazyvim.plugins.extras.lang.svelte" },
    { import = "lazyvim.plugins.extras.ai.copilot" },
    { import = "lazyvim.plugins.extras.dap.core" },
    { import = "plugins" },
  },
  defaults = { lazy = false, version = false },
  -- The lock lives in this repo, which is stdpath("config") on every machine,
  -- so pins are identical everywhere and updates stay deliberate.
  lockfile = vim.fn.stdpath("config") .. "/lazy-lock.json",
  install = { colorscheme = { "catppuccin", "habamax" } },
  -- No update nagging; lazy-lock.json in git is the pin, updates are deliberate.
  checker = { enabled = false },
  change_detection = { notify = false },
  performance = {
    rtp = {
      disabled_plugins = { "gzip", "tarPlugin", "tohtml", "tutor", "zipPlugin" },
    },
  },
})
