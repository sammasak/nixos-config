# Neovim Quick Reference
## Essential Keybindings

### Leader Key
- Leader: `Space`

---

## File Explorer (nvim-tree)
| Keybinding | Action |
|------------|--------|
| `Space + e` | Toggle file explorer |
| `Enter` | Open file/folder |
| `a` | Create new file |
| `d` | Delete file |
| `r` | Rename file |
| `x` | Cut file |
| `c` | Copy file |
| `p` | Paste file |
| `R` | Refresh tree |

---

## Fuzzy Finder (Telescope)
| Keybinding | Action |
|------------|--------|
| `Space + f + f` | Find files |
| `Space + f + g` | Live grep (search in files) |
| `Space + f + b` | Browse buffers |
| `Space + f + h` | Help tags |
| `Ctrl + n` | Next item (in picker) |
| `Ctrl + p` | Previous item (in picker) |
| `Esc` | Close picker |

---

## LSP (Language Server)
| Keybinding | Action |
|------------|--------|
| `K` | Hover documentation |
| `g + d` | Go to definition |
| `g + D` | Go to declaration |
| `g + r` | Show references |
| `g + i` | Go to implementation |
| `Space + c + a` | Code actions |
| `Space + r + n` | Rename symbol |
| `[d` | Previous diagnostic |
| `]d` | Next diagnostic |

---

## Buffer Navigation
| Keybinding | Action |
|------------|--------|
| `:bnext` | Next buffer |
| `:bprev` | Previous buffer |
| `:bd` | Close buffer |
| `Space + f + b` | Browse buffers (Telescope) |

---

## Window Navigation
| Keybinding | Action |
|------------|--------|
| `Ctrl + h` | Move to left window |
| `Ctrl + j` | Move to bottom window |
| `Ctrl + k` | Move to top window |
| `Ctrl + l` | Move to right window |
| `Ctrl + w + s` | Split horizontal |
| `Ctrl + w + v` | Split vertical |
| `Ctrl + w + q` | Close window |

---

## Git (Gitsigns)
| Keybinding | Action |
|------------|--------|
| `]c` | Next hunk |
| `[c` | Previous hunk |
| `Space + h + s` | Stage hunk |
| `Space + h + r` | Reset hunk |
| `Space + h + p` | Preview hunk |
| `Space + h + b` | Blame line |

---

## Treesitter
| Command | Action |
|---------|--------|
| `:TSInstallInfo` | Show installed parsers |
| `:TSUpdate` | Update parsers |
| `:TSModuleInfo` | Show module status |

---

## General Neovim
| Keybinding | Action |
|------------|--------|
| `:w` | Save file |
| `:q` | Quit |
| `:wq` | Save and quit |
| `:q!` | Quit without saving |
| `u` | Undo |
| `Ctrl + r` | Redo |
| `/` | Search forward |
| `?` | Search backward |
| `n` | Next search result |
| `N` | Previous search result |

---

## Health Check Commands
| Command | Action |
|---------|--------|
| `:checkhealth` | Run all health checks |
| `:checkhealth nvim` | Check Neovim core |
| `:checkhealth treesitter` | Check Treesitter |
| `:checkhealth telescope` | Check Telescope |
| `:checkhealth lsp` | Check LSP |

---

## Debugging Commands
| Command | Action |
|---------|--------|
| `:messages` | Show message history |
| `:LspInfo` | Show LSP status |
| `:LspLog` | Show LSP log |
| `:TSInstallInfo` | Show Treesitter parsers |
| `:colorscheme` | Show current theme |

---

## Tips
1. Press `Esc` to return to normal mode
2. Press `i` to enter insert mode
3. Press `v` to enter visual mode
4. Press `:` to enter command mode
5. Type `:help <topic>` for detailed help on any topic
