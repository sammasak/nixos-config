-- Markdown reading/navigation. Kept portable: obsidian.nvim only points at the
-- ~/knowledge vault when that path exists, so it is harmless on a work machine
-- that has no vault.
local vault = vim.fn.expand("~/knowledge")
local have_vault = (vim.uv or vim.loop).fs_stat(vault) ~= nil

return {
  {
    "MeanderingProgrammer/render-markdown.nvim",
    ft = { "markdown" },
    opts = {},
  },
  {
    "obsidian-nvim/obsidian.nvim",
    ft = { "markdown" },
    enabled = have_vault,
    dependencies = { "nvim-lua/plenary.nvim" },
    opts = {
      workspaces = {
        { name = "knowledge", path = vault },
      },
      legacy_commands = false,
      -- The vault convention is relative markdown links, not wikilinks.
      link = { style = "markdown" },
      ui = { enable = false },
    },
  },
}
