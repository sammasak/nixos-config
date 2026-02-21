# Neovim Setup Testing Checklist
## Task 14: Deploy and Test on lenovo-21CB001PMX

### Deployment

Run the deployment script:
```bash
cd /home/lukas/nixos-config
./deploy-and-test.sh
```

Or manually deploy:
```bash
cd /home/lukas/nixos-config
sudo nixos-rebuild switch --flake .#lenovo
```

**Note:** The flake configuration name is "lenovo" (it points to `hosts/lenovo-21CB001PMX/`).

---

## Manual Testing Checklist

### ✓ 1. Verify Neovim Installation

**Check executable location:**
```bash
which nvim
```
Expected output: `/run/current-system/sw/bin/nvim` or similar

**Check version:**
```bash
nvim --version
```
Expected: NVIM v0.10.x or later

---

### ✓ 2. Check Configuration Symlink

```bash
ls -la ~/.config/nvim/
```

Expected output:
- `init.lua` file present
- `lua/` directory present
- Files should be symlinked from Nix store

---

### ✓ 3. Launch Neovim and Run Health Check

```bash
nvim
```

In Neovim, run:
```
:checkhealth
```

**Expected results:**
- ✓ Treesitter: OK
- ✓ Telescope: OK
- ✓ LSP: OK
- ✓ Git signs: OK
- ✓ nvim-tree: OK

Look for any ERROR or WARNING messages and note them.

---

### ✓ 4. Test Treesitter Syntax Highlighting

Open a Nix file:
```bash
nvim /home/lukas/nixos-config/hosts/lenovo-21CB001PMX/configuration.nix
```

**Expected:**
- Syntax highlighting should be visible
- Keywords should be colorized (e.g., `let`, `in`, `inherit`)
- Strings should have distinct colors
- Comments should be highlighted differently

**In Neovim, check Treesitter status:**
```
:TSModuleInfo
```

---

### ✓ 5. Test File Explorer (nvim-tree)

In Neovim, press:
```
Space + e
```

**Expected:**
- File explorer should open on the left side
- Directory structure should be visible
- Current directory should be `/home/lukas/nixos-config`

**Additional tests:**
- Navigate with arrow keys or `j/k`
- Press `Enter` to open a file
- Press `Space + e` again to close the explorer

---

### ✓ 6. Test Fuzzy Finder (Telescope)

In Neovim, press:
```
Space + f + f
```

**Expected:**
- Telescope picker should open (floating window)
- List of files in the project should appear
- You can type to filter files
- Preview pane should show file contents

**Test other Telescope features:**
- `Space + f + g` : Live grep (search text in files)
- `Space + f + b` : Browse open buffers
- `Space + f + h` : Help tags

---

### ✓ 7. Test Git Signs (in a git repo)

If you're in a git repository, open a tracked file:
```bash
cd /some/git/repo
nvim some-file.txt
```

Make a change to the file (add a line, modify a line).

**Expected:**
- Git signs should appear in the gutter (sign column)
- Added lines: `+` symbol
- Modified lines: `~` symbol
- Deleted lines: `-` symbol
- Colors should indicate the type of change

---

### ✓ 8. Test LSP (Language Server Protocol)

Open a Nix file:
```bash
nvim /home/lukas/nixos-config/hosts/lenovo-21CB001PMX/configuration.nix
```

**Test hover documentation:**
- Move cursor over a function or keyword
- Press `K` in normal mode
- Expected: Documentation popup should appear (if nil LSP is configured)

**Test other LSP features:**
- `g + d` : Go to definition
- `g + r` : Show references
- `Space + c + a` : Code actions (if available)

**Check LSP status:**
```
:LspInfo
```

---

### ✓ 9. Test Theme and Appearance

In Neovim, verify the theme is applied:

**Expected:**
- Theme should be "tokyonight" or configured theme
- Line numbers should be visible
- Status line should be visible at the bottom
- Colors should be pleasant and readable

**Check theme:**
```
:colorscheme
```

---

### ✓ 10. Test Additional Keybindings

**Buffer navigation:**
- `:bnext` or `Shift + l` : Next buffer (if configured)
- `:bprev` or `Shift + h` : Previous buffer (if configured)

**Window navigation:**
- `Ctrl + h` : Move to left window
- `Ctrl + j` : Move to bottom window
- `Ctrl + k` : Move to top window
- `Ctrl + l` : Move to right window

**Saving and quitting:**
- `:w` : Save file
- `:q` : Quit
- `:wq` : Save and quit

---

## Troubleshooting

### Issue: Neovim command not found

**Check PATH:**
```bash
echo $PATH
```

**Reload shell:**
```bash
exec $SHELL
```

**Check home-manager generations:**
```bash
home-manager generations
```

---

### Issue: Plugins not loaded

**Check config location:**
```bash
ls -la ~/.config/nvim/
cat ~/.config/nvim/init.lua
```

**Check for errors in headless mode:**
```bash
nvim --headless +checkhealth +quit
```

**Review logs:**
```bash
nvim --headless "+checkhealth" "+w! /tmp/nvim-health.txt" "+qa"
cat /tmp/nvim-health.txt
```

---

### Issue: Treesitter parsers missing

In Neovim:
```
:TSInstallInfo
```

Check which parsers are installed and which are missing.

**Check for errors:**
```
:messages
```

---

### Issue: LSP not working

**Check LSP status:**
```
:LspInfo
```

**Check if nil is installed:**
```bash
which nil
```

**Check LSP logs:**
```
:LspLog
```

---

## Success Criteria

All of the following should be working:
- [x] Neovim launches without errors
- [x] `:checkhealth` shows no critical errors
- [x] Syntax highlighting works (Treesitter)
- [x] File explorer opens with `Space + e`
- [x] Fuzzy finder opens with `Space + f + f`
- [x] Git signs appear in git repositories
- [x] LSP provides hover documentation (if nil is configured)
- [x] Theme is applied correctly
- [x] Keybindings work as expected

---

## Next Steps

Once testing is complete:
1. Note any issues or missing features
2. If everything works: Configuration is ready for production
3. If issues found: Document them and create fix tasks
4. Consider deploying to other hosts (acer-swift, nixos-desktop)

---

## Notes

- Configuration location: `/home/lukas/nixos-config`
- Host: `lenovo-21CB001PMX`
- User: `lukas`
- Neovim config: `~/.config/nvim/` (symlinked from Nix store)
