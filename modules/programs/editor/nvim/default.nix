# Neovim with inline plugin configuration
{ pkgs, ... }:
{
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;

    plugins = with pkgs.vimPlugins; [
      # Treesitter for syntax highlighting
      (nvim-treesitter.withPlugins (p: [
        p.nix p.python p.rust p.markdown p.yaml p.json p.lua p.bash
      ]))

      # Telescope fuzzy finder
      plenary-nvim
      telescope-fzf-native-nvim
      telescope-nvim

      # File explorer
      nvim-web-devicons
      nvim-tree-lua

      # Git integration
      gitsigns-nvim

      # Catppuccin theme (already available via Stylix)
      catppuccin-nvim
    ];

    extraPackages = with pkgs; [
      # Treesitter dependencies
      gcc
      tree-sitter

      # Telescope dependencies
      ripgrep
      fd
    ];

    initLua = ''
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

      -- Keybindings configuration
      local keymap = vim.keymap.set

      -- Set leader key to space
      vim.g.mapleader = " "
      vim.g.maplocalleader = " "

      -- Better window navigation
      keymap("n", "<C-h>", "<C-w>h", { desc = "Move to left window" })
      keymap("n", "<C-j>", "<C-w>j", { desc = "Move to bottom window" })
      keymap("n", "<C-k>", "<C-w>k", { desc = "Move to top window" })
      keymap("n", "<C-l>", "<C-w>l", { desc = "Move to right window" })

      -- Window resizing
      keymap("n", "<C-Up>", ":resize +2<CR>", { desc = "Increase window height" })
      keymap("n", "<C-Down>", ":resize -2<CR>", { desc = "Decrease window height" })
      keymap("n", "<C-Left>", ":vertical resize -2<CR>", { desc = "Decrease window width" })
      keymap("n", "<C-Right>", ":vertical resize +2<CR>", { desc = "Increase window width" })

      -- Buffer navigation
      keymap("n", "<Tab>", ":bnext<CR>", { desc = "Next buffer" })
      keymap("n", "<S-Tab>", ":bprevious<CR>", { desc = "Previous buffer" })
      keymap("n", "<leader>bd", ":bdelete<CR>", { desc = "Delete buffer" })

      -- Clear search highlighting
      keymap("n", "<Esc>", ":nohlsearch<CR>", { desc = "Clear search highlighting" })

      -- Save file
      keymap("n", "<C-s>", ":w<CR>", { desc = "Save file" })
      keymap("i", "<C-s>", "<Esc>:w<CR>a", { desc = "Save file" })

      -- Better indenting
      keymap("v", "<", "<gv", { desc = "Indent left and reselect" })
      keymap("v", ">", ">gv", { desc = "Indent right and reselect" })

      -- Move text up and down
      keymap("v", "J", ":m '>+1<CR>gv=gv", { desc = "Move text down" })
      keymap("v", "K", ":m '<-2<CR>gv=gv", { desc = "Move text up" })

      -- Keep cursor centered when scrolling
      keymap("n", "<C-d>", "<C-d>zz", { desc = "Scroll down and center" })
      keymap("n", "<C-u>", "<C-u>zz", { desc = "Scroll up and center" })
      keymap("n", "n", "nzzzv", { desc = "Next search result centered" })
      keymap("n", "N", "Nzzzv", { desc = "Previous search result centered" })

      -- File explorer (nvim-tree)
      keymap("n", "<leader>e", ":NvimTreeToggle<CR>", { desc = "Toggle file explorer" })

      -- Telescope fuzzy finder
      keymap("n", "<leader>ff", ":Telescope find_files<CR>", { desc = "Find files" })
      keymap("n", "<leader>fg", ":Telescope live_grep<CR>", { desc = "Live grep" })
      keymap("n", "<leader>fb", ":Telescope buffers<CR>", { desc = "Find buffers" })
      keymap("n", "<leader>fh", ":Telescope help_tags<CR>", { desc = "Help tags" })

      -- Git (gitsigns will add more when configured)
      keymap("n", "<leader>gs", ":Telescope git_status<CR>", { desc = "Git status" })

      -- Plugin configurations
      -- Treesitter setup
      require('nvim-treesitter').setup({
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

      -- Telescope setup
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

      -- Nvim-tree setup
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

      -- Gitsigns setup
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

      -- Set colorscheme
      vim.cmd.colorscheme("catppuccin")
    '';
  };
}
