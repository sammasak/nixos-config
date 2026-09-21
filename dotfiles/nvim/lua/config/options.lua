-- Options are applied after LazyVim startup so these user preferences win.
-- https://www.lazyvim.org/configuration/general

vim.opt.clipboard = "unnamedplus"
vim.opt.confirm = true
vim.opt.cursorline = true
vim.opt.diffopt:append({ "algorithm:histogram", "linematch:60", "indent-heuristic" })
vim.opt.expandtab = true
vim.opt.ignorecase = true
vim.opt.inccommand = "split"
vim.opt.laststatus = 3
vim.opt.linebreak = true
vim.opt.list = true
vim.opt.listchars = { tab = "» ", trail = "·", nbsp = "␣" }
vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.scrolloff = 8
vim.opt.shiftwidth = 4
vim.opt.sidescrolloff = 8
vim.opt.smartcase = true
vim.opt.splitbelow = true
vim.opt.splitright = true
vim.opt.tabstop = 4
vim.opt.termguicolors = true
vim.opt.timeoutlen = 500
vim.opt.undofile = true
vim.opt.updatetime = 250
vim.opt.wrap = false
