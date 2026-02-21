-- lazy.nvim setup for Nix-installed plugins
-- lazy.nvim will load plugins from runtimepath (Nix store)

require("lazy").setup({
  -- Just tell lazy about the plugins so it loads them
  -- They're already installed by Nix, lazy just needs to know they exist
  { "nvim-treesitter/nvim-treesitter" },
  { "nvim-telescope/telescope.nvim" },
  { "nvim-tree/nvim-tree.lua" },
  { "lewis6991/gitsigns.nvim" },
}, {
  performance = {
    reset_packpath = false,  -- Don't reset, we need Nix paths
    rtp = {
      reset = false,  -- Don't reset runtime path
    },
  },
  install = {
    missing = false,  -- Don't try to install, they're from Nix
  },
  ui = {
    border = "rounded",
  },
})

-- Now configure each plugin after lazy has loaded them

-- Treesitter configuration
require("nvim-treesitter.configs").setup({
  auto_install = false,
  highlight = {
    enable = true,
    additional_vim_regex_highlighting = false,
  },
  indent = {
    enable = true,
  },
  incremental_selection = {
    enable = true,
    keymaps = {
      init_selection = "<CR>",
      node_incremental = "<CR>",
      scope_incremental = "<S-CR>",
      node_decremental = "<BS>",
    },
  },
})

-- Telescope configuration
local telescope = require("telescope")
local actions = require("telescope.actions")
telescope.setup({
  defaults = {
    prompt_prefix = "   ",
    selection_caret = " ",
    path_display = { "truncate" },
    sorting_strategy = "ascending",
    layout_config = {
      horizontal = {
        prompt_position = "top",
        preview_width = 0.55,
      },
      width = 0.87,
      height = 0.80,
    },
    mappings = {
      i = {
        ["<C-j>"] = actions.move_selection_next,
        ["<C-k>"] = actions.move_selection_previous,
        ["<Esc>"] = actions.close,
      },
    },
  },
})
telescope.load_extension("fzf")

-- nvim-tree configuration
require("nvim-tree").setup({
  disable_netrw = true,
  hijack_cursor = true,
  sync_root_with_cwd = true,
  update_focused_file = {
    enable = true,
    update_root = false,
  },
  view = {
    width = 30,
    side = "left",
  },
  renderer = {
    group_empty = true,
    highlight_git = true,
    icons = {
      show = {
        file = true,
        folder = true,
        folder_arrow = true,
        git = true,
      },
    },
  },
  filters = {
    dotfiles = false,
    custom = { ".git", "node_modules", ".cache" },
  },
})

-- Gitsigns configuration
require("gitsigns").setup({
  signs = {
    add = { text = "│" },
    change = { text = "│" },
    delete = { text = "_" },
    topdelete = { text = "‾" },
    changedelete = { text = "~" },
    untracked = { text = "┆" },
  },
  on_attach = function(bufnr)
    local gs = package.loaded.gitsigns

    local function map(mode, l, r, opts)
      opts = opts or {}
      opts.buffer = bufnr
      vim.keymap.set(mode, l, r, opts)
    end

    -- Navigation
    map("n", "]c", function()
      if vim.wo.diff then return "]c" end
      vim.schedule(function() gs.next_hunk() end)
      return "<Ignore>"
    end, { expr = true, desc = "Next git hunk" })

    map("n", "[c", function()
      if vim.wo.diff then return "[c" end
      vim.schedule(function() gs.prev_hunk() end)
      return "<Ignore>"
    end, { expr = true, desc = "Previous git hunk" })

    -- Actions
    map("n", "<leader>hs", gs.stage_hunk, { desc = "Stage hunk" })
    map("n", "<leader>hr", gs.reset_hunk, { desc = "Reset hunk" })
    map("n", "<leader>hS", gs.stage_buffer, { desc = "Stage buffer" })
    map("n", "<leader>hu", gs.undo_stage_hunk, { desc = "Undo stage hunk" })
    map("n", "<leader>hR", gs.reset_buffer, { desc = "Reset buffer" })
    map("n", "<leader>hp", gs.preview_hunk, { desc = "Preview hunk" })
    map("n", "<leader>hb", function() gs.blame_line({ full = true }) end, { desc = "Blame line" })
    map("n", "<leader>hd", gs.diffthis, { desc = "Diff this" })
  end,
})

-- Set colorscheme (catppuccin from Stylix)
vim.cmd.colorscheme("catppuccin")
