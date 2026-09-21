-- Extra autocmds on top of LazyVim defaults.
local group = vim.api.nvim_create_augroup("user_autocmds", { clear = true })

vim.api.nvim_create_autocmd("TextYankPost", {
  group = group,
  callback = function()
    vim.highlight.on_yank({ higroup = "IncSearch", timeout = 150 })
  end,
})

vim.api.nvim_create_autocmd("BufReadPost", {
  group = group,
  callback = function()
    local mark = vim.api.nvim_buf_get_mark(0, '"')
    if mark[1] > 0 and mark[1] <= vim.api.nvim_buf_line_count(0) then
      pcall(vim.api.nvim_win_set_cursor, 0, mark)
    end
  end,
})

vim.diagnostic.config({
  float = { border = "rounded", source = "if_many" },
  severity_sort = true,
  underline = true,
  virtual_text = { spacing = 2, source = "if_many" },
})
