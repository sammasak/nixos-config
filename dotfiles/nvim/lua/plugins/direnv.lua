-- The plug-into-any-repo glue: applies the repo's .envrc environment inside
-- nvim itself, so LSP servers spawn from that repo's devshell PATH even when
-- nvim was launched from rofi or another directory.
return {
  {
    "direnv/direnv.vim",
    lazy = false,
    init = function()
      vim.g.direnv_silent_load = 1
    end,
  },
}
