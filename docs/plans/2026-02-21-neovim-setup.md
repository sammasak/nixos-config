# Neovim Setup Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add Neovim with lazy.nvim + lazy-nix-helper to all NixOS hosts with beginner-friendly minimal configuration.

**Architecture:** Hybrid approach using Nix to declare and install plugins reproducibly, while using lazy.nvim for configuration and lazy-loading. Configuration follows standard Neovim patterns (Lua in `~/.config/nvim/`) bridged to Nix-installed plugins via lazy-nix-helper.

**Tech Stack:** NixOS, Home Manager, Neovim, lazy.nvim, lazy-nix-helper, treesitter, telescope, nvim-tree

---

## Task 1: Create Nix Module Directory Structure

**Files:**
- Create: `modules/programs/editor/nvim/default.nix`

**Step 1: Create module directory**

Run:
```bash
mkdir -p /home/lukas/nixos-config/modules/programs/editor/nvim
```

Expected: Directory created without errors

**Step 2: Create placeholder Nix module**

Create `modules/programs/editor/nvim/default.nix`:
```nix
# Neovim with lazy.nvim + lazy-nix-helper
{ pkgs, ... }:
{
  # Placeholder - will be implemented in next task
  programs.neovim.enable = true;
}
```

**Step 3: Verify syntax**

Run:
```bash
cd /home/lukas/nixos-config
nix-instantiate --parse modules/programs/editor/nvim/default.nix
```

Expected: No syntax errors

**Step 4: Commit**

```bash
git add modules/programs/editor/nvim/default.nix
git commit -m "feat(nvim): create neovim module structure

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

---

## Task 2: Implement Nix Module with Plugin Declarations

**Files:**
- Modify: `modules/programs/editor/nvim/default.nix`

**Step 1: Write complete Nix module**

Replace contents of `modules/programs/editor/nvim/default.nix`:

```nix
# Neovim with lazy.nvim + lazy-nix-helper
{ pkgs, ... }:
{
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;

    plugins = with pkgs.vimPlugins; [
      # Plugin manager and bridge
      lazy-nvim
      lazy-nix-helper-nvim

      # Treesitter for syntax highlighting
      nvim-treesitter.withAllGrammars

      # Fuzzy finder
      telescope-nvim
      telescope-fzf-native-nvim
      plenary-nvim

      # File explorer
      nvim-tree-lua
      nvim-web-devicons

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
  };

  # Symlink Neovim config from dotfiles
  xdg.configFile."nvim".source = ../../../../dotfiles/nvim;
}
```

**Step 2: Verify syntax**

Run:
```bash
nix-instantiate --parse modules/programs/editor/nvim/default.nix
```

Expected: No syntax errors

**Step 3: Commit**

```bash
git add modules/programs/editor/nvim/default.nix
git commit -m "feat(nvim): declare plugins via Nix

Add lazy.nvim, lazy-nix-helper, treesitter, telescope, nvim-tree,
and gitsigns with required system dependencies.

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

---

## Task 3: Create Lua Configuration Directory Structure

**Files:**
- Create: `dotfiles/nvim/init.lua`
- Create: `dotfiles/nvim/lua/config/options.lua`
- Create: `dotfiles/nvim/lua/config/keymaps.lua`
- Create: `dotfiles/nvim/lua/plugins/lazy-nix-helper.lua`
- Create: `dotfiles/nvim/lua/plugins/treesitter.lua`
- Create: `dotfiles/nvim/lua/plugins/telescope.lua`
- Create: `dotfiles/nvim/lua/plugins/nvim-tree.lua`
- Create: `dotfiles/nvim/lua/plugins/gitsigns.lua`

**Step 1: Create directory structure**

Run:
```bash
mkdir -p /home/lukas/nixos-config/dotfiles/nvim/lua/{config,plugins}
```

Expected: Directories created

**Step 2: Verify structure**

Run:
```bash
tree /home/lukas/nixos-config/dotfiles/nvim
```

Expected:
```
nvim/
└── lua/
    ├── config/
    └── plugins/
```

**Step 3: Commit**

```bash
git add dotfiles/nvim/
git commit -m "feat(nvim): create lua config directory structure

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

---

## Task 4: Create init.lua Entry Point

**Files:**
- Create: `dotfiles/nvim/init.lua`

**Step 1: Write init.lua**

Create `dotfiles/nvim/init.lua`:
```lua
-- Neovim init.lua
-- Bootstrap and load configuration

-- Load basic options first
require("config.options")
require("config.keymaps")

-- Initialize lazy.nvim with lazy-nix-helper
require("plugins.lazy-nix-helper")
```

**Step 2: Verify Lua syntax**

Run:
```bash
lua -c "dofile('/home/lukas/nixos-config/dotfiles/nvim/init.lua')"
```

Expected: May error on missing modules (that's OK), but no syntax errors

**Step 3: Commit**

```bash
git add dotfiles/nvim/init.lua
git commit -m "feat(nvim): add init.lua entry point

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

---

## Task 5: Create Vim Options Configuration

**Files:**
- Create: `dotfiles/nvim/lua/config/options.lua`

**Step 1: Write options.lua**

Create `dotfiles/nvim/lua/config/options.lua`:
```lua
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
```

**Step 2: Verify Lua syntax**

Run:
```bash
lua -c "dofile('/home/lukas/nixos-config/dotfiles/nvim/lua/config/options.lua')"
```

Expected: No syntax errors (may have vim.opt warnings, ignore)

**Step 3: Commit**

```bash
git add dotfiles/nvim/lua/config/options.lua
git commit -m "feat(nvim): add vim options configuration

Configure line numbers, indentation, search, appearance, splits,
clipboard, undo, and performance settings.

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

---

## Task 6: Create Keymaps Configuration

**Files:**
- Create: `dotfiles/nvim/lua/config/keymaps.lua`

**Step 1: Write keymaps.lua**

Create `dotfiles/nvim/lua/config/keymaps.lua`:
```lua
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
```

**Step 2: Verify Lua syntax**

Run:
```bash
lua -c "dofile('/home/lukas/nixos-config/dotfiles/nvim/lua/config/keymaps.lua')"
```

Expected: No syntax errors

**Step 3: Commit**

```bash
git add dotfiles/nvim/lua/config/keymaps.lua
git commit -m "feat(nvim): add keybindings configuration

Set leader key to space, configure window navigation, buffer
management, file explorer, fuzzy finder, and git shortcuts.

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

---

## Task 7: Configure lazy-nix-helper Bridge

**Files:**
- Create: `dotfiles/nvim/lua/plugins/lazy-nix-helper.lua`

**Step 1: Write lazy-nix-helper.lua**

Create `dotfiles/nvim/lua/plugins/lazy-nix-helper.lua`:
```lua
-- lazy-nix-helper: Bridge between Nix-installed plugins and lazy.nvim
local lazy_nix_helper = require("lazy-nix-helper")

-- Setup lazy.nvim with Nix-installed plugins
require("lazy").setup({
  -- Plugin configurations
  { import = "plugins.treesitter" },
  { import = "plugins.telescope" },
  { import = "plugins.nvim-tree" },
  { import = "plugins.gitsigns" },
}, {
  -- Use Nix-installed plugins
  performance = {
    reset_packpath = false,
    rtp = {
      reset = false,
    },
  },
  dev = {
    path = lazy_nix_helper.pluginPath,
  },
  install = {
    -- Don't install plugins, they're from Nix
    missing = false,
  },
  ui = {
    border = "rounded",
  },
})

-- Set colorscheme (catppuccin from Stylix)
vim.cmd.colorscheme("catppuccin")
```

**Step 2: Verify Lua syntax**

Run:
```bash
lua -c "dofile('/home/lukas/nixos-config/dotfiles/nvim/lua/plugins/lazy-nix-helper.lua')"
```

Expected: May error on missing requires (OK), but no syntax errors

**Step 3: Commit**

```bash
git add dotfiles/nvim/lua/plugins/lazy-nix-helper.lua
git commit -m "feat(nvim): configure lazy-nix-helper bridge

Setup lazy.nvim to use Nix-installed plugins and load plugin configs.

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

---

## Task 8: Configure Treesitter for Syntax Highlighting

**Files:**
- Create: `dotfiles/nvim/lua/plugins/treesitter.lua`

**Step 1: Write treesitter.lua**

Create `dotfiles/nvim/lua/plugins/treesitter.lua`:
```lua
-- Treesitter configuration for syntax highlighting
return {
  "nvim-treesitter/nvim-treesitter",
  event = { "BufReadPost", "BufNewFile" },
  config = function()
    require("nvim-treesitter.configs").setup({
      -- Grammars installed via Nix (withAllGrammars)
      auto_install = false,

      -- Enable syntax highlighting
      highlight = {
        enable = true,
        additional_vim_regex_highlighting = false,
      },

      -- Enable smart indentation
      indent = {
        enable = true,
      },

      -- Enable incremental selection
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
  end,
}
```

**Step 2: Verify Lua syntax**

Run:
```bash
lua -c "dofile('/home/lukas/nixos-config/dotfiles/nvim/lua/plugins/treesitter.lua')"
```

Expected: No syntax errors

**Step 3: Commit**

```bash
git add dotfiles/nvim/lua/plugins/treesitter.lua
git commit -m "feat(nvim): configure treesitter for syntax highlighting

Enable highlight, indentation, and incremental selection.

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

---

## Task 9: Configure Telescope Fuzzy Finder

**Files:**
- Create: `dotfiles/nvim/lua/plugins/telescope.lua`

**Step 1: Write telescope.lua**

Create `dotfiles/nvim/lua/plugins/telescope.lua`:
```lua
-- Telescope fuzzy finder configuration
return {
  "nvim-telescope/telescope.nvim",
  cmd = "Telescope",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-telescope/telescope-fzf-native.nvim",
  },
  config = function()
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

    -- Load fzf native extension for better performance
    telescope.load_extension("fzf")
  end,
}
```

**Step 2: Verify Lua syntax**

Run:
```bash
lua -c "dofile('/home/lukas/nixos-config/dotfiles/nvim/lua/plugins/telescope.lua')"
```

Expected: No syntax errors

**Step 3: Commit**

```bash
git add dotfiles/nvim/lua/plugins/telescope.lua
git commit -m "feat(nvim): configure telescope fuzzy finder

Setup telescope with fzf extension and custom keybindings.

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

---

## Task 10: Configure nvim-tree File Explorer

**Files:**
- Create: `dotfiles/nvim/lua/plugins/nvim-tree.lua`

**Step 1: Write nvim-tree.lua**

Create `dotfiles/nvim/lua/plugins/nvim-tree.lua`:
```lua
-- nvim-tree file explorer configuration
return {
  "nvim-tree/nvim-tree.lua",
  cmd = { "NvimTreeToggle", "NvimTreeFocus" },
  config = function()
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
  end,
}
```

**Step 2: Verify Lua syntax**

Run:
```bash
lua -c "dofile('/home/lukas/nixos-config/dotfiles/nvim/lua/plugins/nvim-tree.lua')"
```

Expected: No syntax errors

**Step 3: Commit**

```bash
git add dotfiles/nvim/lua/plugins/nvim-tree.lua
git commit -m "feat(nvim): configure nvim-tree file explorer

Setup file explorer with git integration and custom filters.

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

---

## Task 11: Configure Gitsigns

**Files:**
- Create: `dotfiles/nvim/lua/plugins/gitsigns.lua`

**Step 1: Write gitsigns.lua**

Create `dotfiles/nvim/lua/plugins/gitsigns.lua`:
```lua
-- Gitsigns configuration for git integration
return {
  "lewis6991/gitsigns.nvim",
  event = { "BufReadPre", "BufNewFile" },
  config = function()
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
  end,
}
```

**Step 2: Verify Lua syntax**

Run:
```bash
lua -c "dofile('/home/lukas/nixos-config/dotfiles/nvim/lua/plugins/gitsigns.lua')"
```

Expected: No syntax errors

**Step 3: Commit**

```bash
git add dotfiles/nvim/lua/plugins/gitsigns.lua
git commit -m "feat(nvim): configure gitsigns for git integration

Add git signs in gutter and keybindings for hunk navigation.

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

---

## Task 12: Wire Neovim Module into Home Manager

**Files:**
- Modify: `modules/home/default.nix:6-10`

**Step 1: Read current home module**

Run:
```bash
cat modules/home/default.nix
```

Expected: See current imports structure

**Step 2: Add nvim to baseImports**

Modify `modules/home/default.nix`, change `baseImports` from:
```nix
  baseImports = [
    ../core/fish.nix
    ../programs/cli/git
    ../programs/cli/cli-tools
  ];
```

To:
```nix
  baseImports = [
    ../core/fish.nix
    ../programs/cli/git
    ../programs/cli/cli-tools
    ../programs/editor/nvim
  ];
```

**Step 3: Verify syntax**

Run:
```bash
nix-instantiate --parse modules/home/default.nix
```

Expected: No syntax errors

**Step 4: Commit**

```bash
git add modules/home/default.nix
git commit -m "feat(nvim): wire neovim module into home-manager

Add nvim to baseImports so all hosts get neovim configured.

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

---

## Task 13: Build and Validate Configuration

**Files:**
- None (testing only)

**Step 1: Run flake check**

Run:
```bash
cd /home/lukas/nixos-config
nix flake check --all-systems --no-write-lock-file
```

Expected: No errors (warnings OK)

**Step 2: Build a test host configuration**

Run:
```bash
nix build .#nixosConfigurations.acer-swift.config.system.build.toplevel --no-link
```

Expected: Build succeeds without errors

**Step 3: Check symlink target exists**

Run:
```bash
ls -la dotfiles/nvim/
```

Expected: See init.lua and lua/ directory

**Step 4: Verify no untracked files**

Run:
```bash
git status
```

Expected: Working tree clean (all files committed)

---

## Task 14: Deploy and Test on One Host

**Files:**
- None (deployment and manual testing)

**Step 1: Deploy to acer-swift**

Run:
```bash
sudo nixos-rebuild switch --flake .#acer-swift
```

Expected: Rebuild succeeds, home-manager activates

**Step 2: Verify Neovim installed**

Run:
```bash
which nvim
nvim --version
```

Expected: Neovim found, version displayed (v0.9+)

**Step 3: Verify config symlinked**

Run:
```bash
ls -la ~/.config/nvim/
```

Expected: Symlink to dotfiles/nvim/ with init.lua and lua/ visible

**Step 4: Launch Neovim and check for errors**

Run:
```bash
nvim
```

In Neovim, run:
```
:checkhealth
```

Expected:
- No critical errors
- lazy.nvim loaded
- Treesitter working
- Telescope working

**Step 5: Test treesitter syntax highlighting**

In Neovim:
```
:edit ~/.config/nvim/init.lua
```

Expected: Lua syntax highlighted with colors

**Step 6: Test file explorer**

In Neovim, press:
```
<Space>e
```

Expected: nvim-tree opens on left side

**Step 7: Test fuzzy finder**

In Neovim, press:
```
<Space>ff
```

Expected: Telescope file finder opens

**Step 8: Test git signs**

In Neovim, open a tracked file with changes:
```
:edit modules/home/default.nix
```

Expected: Git signs visible in gutter if file has changes

**Step 9: Exit Neovim**

In Neovim:
```
:qa
```

Expected: Neovim exits cleanly

---

## Task 15: Update CLAUDE.md Documentation

**Files:**
- Modify: `CLAUDE.md` (add section about Neovim)

**Step 1: Read current CLAUDE.md**

Run:
```bash
grep -n "## " CLAUDE.md | head -20
```

Expected: See section headers

**Step 2: Add Neovim section after Claude Code section**

Find the Claude Code section and add after it:

```markdown
### Neovim

Configuration lives in `modules/programs/editor/nvim/` and `dotfiles/nvim/`.

**Approach:** Hybrid - plugins installed via Nix, configuration in Lua via lazy.nvim + lazy-nix-helper.

**Configuration files:**
- `dotfiles/nvim/init.lua` - Entry point
- `dotfiles/nvim/lua/config/options.lua` - Vim options
- `dotfiles/nvim/lua/config/keymaps.lua` - Keybindings
- `dotfiles/nvim/lua/plugins/*.lua` - Plugin configurations

**Leader key:** Space

**Key bindings:**
- `<Space>e` - Toggle file explorer (nvim-tree)
- `<Space>ff` - Find files (telescope)
- `<Space>fg` - Live grep (telescope)
- `<Space>fb` - Find buffers (telescope)
- `Tab` / `Shift+Tab` - Next/previous buffer
- `Ctrl+h/j/k/l` - Navigate windows

**Plugins managed by Nix:**
- lazy.nvim - Plugin manager
- lazy-nix-helper - Bridge to Nix
- nvim-treesitter - Syntax highlighting (Nix, Python, Rust, Markdown, YAML, JSON, Lua, Bash)
- telescope.nvim - Fuzzy finder
- nvim-tree.lua - File explorer
- gitsigns.nvim - Git integration
- catppuccin-nvim - Color scheme

**Adding new plugins:**
1. Add plugin to `programs.neovim.plugins` in `modules/programs/editor/nvim/default.nix`
2. Create config file in `dotfiles/nvim/lua/plugins/<plugin-name>.lua`
3. Import in `dotfiles/nvim/lua/plugins/lazy-nix-helper.lua`
4. Rebuild: `sudo nixos-rebuild switch --flake .#<hostname>`
```

**Step 3: Verify markdown syntax**

Run:
```bash
tail -50 CLAUDE.md
```

Expected: New section properly formatted

**Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document neovim configuration in CLAUDE.md

Add neovim section with configuration structure, keybindings,
and plugin management workflow.

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

---

## Task 16: Final Validation and Cleanup

**Files:**
- None (validation only)

**Step 1: Verify all files committed**

Run:
```bash
git status
```

Expected: Working tree clean

**Step 2: Review commit history**

Run:
```bash
git log --oneline -10
```

Expected: See all neovim-related commits

**Step 3: Verify flake check passes**

Run:
```bash
nix flake check --all-systems --no-write-lock-file
```

Expected: No errors

**Step 4: Test on second host (optional but recommended)**

If possible, deploy to lenovo-21CB001PMX or another host:
```bash
sudo nixos-rebuild switch --flake .#lenovo-21CB001PMX
```

Expected: Neovim works identically

**Step 5: Document any issues encountered**

If any issues found during testing, document in:
```
docs/plans/2026-02-21-neovim-setup-issues.md
```

---

## Success Criteria

- [ ] All commits made with descriptive messages
- [ ] Nix module syntax valid (flake check passes)
- [ ] Build succeeds for at least one host
- [ ] Neovim launches without errors
- [ ] Treesitter syntax highlighting works
- [ ] Telescope fuzzy finder functional
- [ ] File explorer (nvim-tree) functional
- [ ] Git signs visible in gutter
- [ ] All keybindings work as documented
- [ ] Configuration symlinked from dotfiles/
- [ ] CLAUDE.md updated with neovim documentation
- [ ] Working tree clean (all files committed)

## Troubleshooting

**Issue:** `lazy-nix-helper` not found
**Fix:** Ensure `lazy-nix-helper-nvim` is in plugins list (check spelling)

**Issue:** Treesitter syntax not working
**Fix:** Verify `nvim-treesitter.withAllGrammars` in Nix module

**Issue:** Telescope not finding files
**Fix:** Check `ripgrep` and `fd` in `extraPackages`

**Issue:** Config not loaded
**Fix:** Verify symlink: `ls -la ~/.config/nvim` should point to dotfiles

**Issue:** Plugins not found by lazy.nvim
**Fix:** Check `lazy-nix-helper.lua` properly configures `dev.path`

## Next Steps After Completion

This minimal setup provides foundation for future enhancements:

1. **LSP support** - Add `nvim-lspconfig` + language servers (nil for Nix, pyright for Python, rust-analyzer for Rust)
2. **Completion** - Add `nvim-cmp` with completion sources
3. **Statusline** - Add `lualine.nvim` for better statusline
4. **Git UI** - Add `lazygit.nvim` or `diffview.nvim`
5. **Debugging** - Add `nvim-dap` for debugging support
6. **Snippets** - Add `LuaSnip` for code snippets
7. **Which-key** - Add `which-key.nvim` for keybinding hints

Each enhancement follows same pattern:
1. Add plugin to Nix module
2. Create config file in `lua/plugins/`
3. Import in lazy-nix-helper
4. Rebuild
