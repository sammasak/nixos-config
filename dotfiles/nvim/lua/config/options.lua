-- Vim options configuration
local opt = vim.opt

-- Line numbers
opt.number = true
opt.relativenumber = true

-- Indentation
opt.tabstop = 2
opt.shiftwidth = 2
opt.expandtab = true
opt.smartindent = true
opt.autoindent = true

-- Search
opt.ignorecase = true
opt.smartcase = true
opt.hlsearch = true
opt.incsearch = true

-- Appearance
opt.termguicolors = true
opt.cursorline = true
opt.signcolumn = "yes"
opt.wrap = false

-- Splits
opt.splitright = true
opt.splitbelow = true

-- Scrolling
opt.scrolloff = 8
opt.sidescrolloff = 8

-- Clipboard (use system clipboard)
opt.clipboard = "unnamedplus"

-- Undo
opt.undofile = true
opt.undolevels = 10000

-- Performance
opt.updatetime = 250
opt.timeoutlen = 300

-- Backups
opt.backup = false
opt.writebackup = false
opt.swapfile = false

-- Completion
opt.completeopt = { "menu", "menuone", "noselect" }

-- Mouse
opt.mouse = "a"

-- Enable global statusline
opt.laststatus = 3
