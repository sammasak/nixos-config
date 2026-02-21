# Neovim Setup Design

**Date:** 2026-02-21
**Status:** Approved

## Overview

Add Neovim with a beginner-friendly minimal configuration to all NixOS hosts using lazy.nvim + lazy-nix-helper. This approach provides a reproducible setup via Nix while following standard Neovim configuration patterns.

## Goals

- Provide Neovim on all hosts (desktop and server modes)
- Minimal starter configuration suitable for Neovim beginners
- Fully reproducible plugin installation via Nix
- Standard lazy.nvim configuration patterns for easy learning
- Syntax highlighting for primary languages: Nix, Python, Rust, Markdown, YAML, JSON

## Architecture

### Approach: lazy.nvim + lazy-nix-helper (Hybrid)

**Why this approach:**
- Plugins managed by Nix (reproducible, version-controlled)
- Configuration follows standard lazy.nvim patterns
- Easy to follow community tutorials
- Fast startup with lazy loading
- Best of both Nix and Neovim ecosystems

**Alternative approaches considered:**
1. **Pure Nix (programs.neovim)** - Rejected: less flexible, harder to extend
2. **NixVim** - Rejected: slower startup, different from standard tutorials
3. **External config flake** - Rejected: overkill for minimal setup

### File Structure

```
nixos-config/
├── modules/programs/editor/nvim/
│   └── default.nix              # Home Manager module
├── dotfiles/nvim/
│   ├── init.lua                 # Entry point, bootstrap lazy.nvim
│   └── lua/
│       ├── config/
│       │   ├── options.lua      # Vim options
│       │   └── keymaps.lua      # Key bindings
│       └── plugins/
│           ├── lazy-nix-helper.lua   # Bridge to Nix plugins
│           ├── treesitter.lua        # Syntax highlighting
│           └── (future plugins)
```

### Integration Points

1. **Module import:** Add `../programs/editor/nvim` to `modules/home/default.nix` in `baseImports` (so all hosts get it)
2. **Config symlink:** `dotfiles/nvim/` → `~/.config/nvim/` via Home Manager
3. **Nix declares plugins:** All plugins installed to `/nix/store`
4. **lazy-nix-helper bridges:** Tells lazy.nvim where to find Nix-installed plugins

## Components

### Nix Module (modules/programs/editor/nvim/default.nix)

**Declares:**
- Neovim package with `programs.neovim.enable = true`
- System dependencies: `gcc` (treesitter compiler), `ripgrep`, `fd`
- Plugins via `programs.neovim.plugins`:
  - `lazy-nix-helper.nvim` - bridge to lazy.nvim
  - `lazy.nvim` - plugin manager
  - `nvim-treesitter` with grammars: nix, python, rust, markdown, yaml, json, lua, bash
  - `gitsigns.nvim` - git indicators in gutter
  - `telescope.nvim` + `telescope-fzf-native.nvim` + `plenary.nvim` - fuzzy finder
  - `nvim-tree.lua` + `nvim-web-devicons` - file explorer
- Symlink `dotfiles/nvim/` to `~/.config/nvim/` via `xdg.configFile."nvim".source`

### Lua Configuration

**init.lua:**
- Bootstrap lazy.nvim (no-op since installed via Nix)
- Load `lua/config/options.lua`
- Load `lua/config/keymaps.lua`
- Initialize lazy.nvim with lazy-nix-helper integration
- Set colorscheme (catppuccin, already available via Stylix)

**lua/config/options.lua:**
- Line numbers: `number = true`, `relativenumber = true`
- Indentation: `tabstop = 2`, `shiftwidth = 2`, `expandtab = true`, `smartindent = true`
- Search: `ignorecase = true`, `smartcase = true`, `hlsearch = true`, `incsearch = true`
- Clipboard: `clipboard = "unnamedplus"` (system clipboard)
- Splits: `splitright = true`, `splitbelow = true`
- Undo: `undofile = true` (persistent undo)
- Scrolling: `scrolloff = 8`, `sidescrolloff = 8` (keep cursor centered)
- UI: `termguicolors = true`, `cursorline = true`, `signcolumn = "yes"`

**lua/config/keymaps.lua:**
- Leader key: `<Space>`
- Window navigation: `Ctrl+h/j/k/l`
- Buffer navigation: `Tab` (next), `Shift+Tab` (previous)
- File explorer: `<Space>e` (toggle nvim-tree)
- Fuzzy finder: `<Space>ff` (find files), `<Space>fg` (live grep), `<Space>fb` (buffers)
- Save: `Ctrl+s`
- Clear search: `<Esc>`
- Split navigation improvements

**lua/plugins/lazy-nix-helper.lua:**
- Require and setup lazy-nix-helper
- Configure to use Nix-installed plugins

**lua/plugins/treesitter.lua:**
- Enable syntax highlighting
- Enable smart indentation
- Configure parsers for: nix, python, rust, markdown, yaml, json, lua, bash

## Testing Strategy

1. **Build test:** `nix build .#nixosConfigurations.acer-swift.config.system.build.toplevel`
2. **Manual verification:**
   - Deploy to a host
   - Open `nvim`, check no errors
   - Verify treesitter syntax highlighting works
   - Test telescope fuzzy finder
   - Test file explorer
   - Verify keybindings work
3. **Cross-host validation:** Test on both desktop and server modes

## Rollout

1. Create `modules/programs/editor/nvim/default.nix`
2. Create `dotfiles/nvim/` directory structure with all Lua config files
3. Add module import to `modules/home/default.nix`
4. Test build
5. Deploy to one host (acer-swift desktop mode recommended)
6. Verify functionality
7. Document in CLAUDE.md if needed

## Future Extensions

This minimal setup provides a foundation for future enhancements:
- LSP support (language servers)
- Completion engine (nvim-cmp)
- Statusline (lualine)
- Git integration (fugitive, diffview)
- Additional language-specific plugins

Users can add these by declaring new plugins in the Nix module and creating corresponding config files in `lua/plugins/`.

## Success Criteria

- [ ] Neovim launches without errors on all hosts
- [ ] Syntax highlighting works for Nix, Python, Rust, Markdown, YAML, JSON
- [ ] Telescope fuzzy finder functional (file search, grep)
- [ ] File explorer (nvim-tree) functional
- [ ] All keybindings work as documented
- [ ] Configuration is reproducible across hosts
- [ ] Git signs visible in gutter when editing tracked files
