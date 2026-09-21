# nvim-config

One LazyVim-based Neovim config, identical on every machine — NixOS at home,
no-nix at work — that **automatically adopts each project's tooling and LSP
servers** from whatever the project provides.

## The idea in one line

`nvim` never hardcodes toolchains. Each project puts its tools on `PATH`
(nix devshell at home, `mise` + `node_modules/.bin` at work) and **direnv**
loads that into the editor, so the right LSP/formatter/linter just appears.

## How "adopt from the project" works

```
 project root ──has──▶ .envrc  ──direnv──▶ PATH gains the project's tools
                                              │
                                    nvim (direnv plugin)
                                              │
                                    LSP/formatter spawn from that PATH
```

- **Home (NixOS):** `.envrc` = `use flake` / devenv → the repo's devshell is
  prepended to `PATH`, so its `rust-analyzer`, formatters, linters, Python
  interpreter, and test runner win. NixOS also supplies a native fallback for
  common tools, so a new checkout remains usable before its devshell is ready.
  Mason is **off** (its prebuilt binaries can't run on NixOS).
- **Work (no nix):** `.envrc` = `PATH_add node_modules/.bin` + `use mise` →
  the project's own toolchain provides the servers. Mason is **on** as a
  fallback so a repo with *no* project tooling still gets working LSPs.

The only thing that differs between machines is one runtime check in
`lua/plugins/lsp.lua` (`/etc/NIXOS` present → Mason off). Every other file is
byte-identical everywhere. Plugin versions are pinned by `lazy-lock.json`.

### Tool precedence

1. `direnv` evaluates the repository's `.envrc` when Neovim opens a project.
2. `use flake`, `use devenv`, `use mise`, or `PATH_add` updates Neovim's child
   process environment; LSPs and formatters are resolved from that `PATH`.
3. NixOS/Home Manager packages are the fallback when the repository provides
   no matching executable.

This means a project can pin its own `rust-analyzer`, Ruff, Pyright-compatible
server, `rustfmt`, pytest, or `uv` without changing the workstation. Run
`:LspInfo` and `:ConformInfo` to see the executable currently selected. Use
`:ProjectInfo` (or `<leader>cp`) to inspect the project root, direnv and
virtualenv state, and executable provenance. If a devshell was entered after
the buffer opened, use `:LspRestart`.

## Install

### Work / any non-nix machine

```bash
git clone <this-repo> ~/nvim-config
~/nvim-config/bootstrap.sh      # installs mise+neovim+direnv (no root), links ~/.config/nvim
exec $SHELL                     # pick up the mise/direnv shell hooks
nvim                            # LazyVim bootstraps + installs pinned plugins
```

Then, per project:

```bash
cp ~/nvim-config/.envrc.example    .envrc       # edit for the project
cp ~/nvim-config/mise.toml.example mise.toml     # optional: pin tool versions
direnv allow
mise install                                      # if you used mise.toml
```

### Home (NixOS)

Home Manager provides Neovim, native dependencies, and fallback language
servers; this repo supplies the Lua config. See the parent nixos-config for
wiring (`modules/programs/editor/nvim`). Mason auto-disables on NixOS.

## Help and discovery

- Press `<Space>` in Normal mode and wait for `which-key.nvim` to show the
  available command tree; `<leader>` is configured as `<Space>`.
- `<leader>?` shows mappings for the current buffer, while `:Lazy`, `:checkhealth`,
  `:LspInfo`, `:ConformInfo`, and `:ProjectInfo` diagnose the surrounding stack.
- Start typing a group such as `<leader>c` (code), `<leader>d` (debug),
  `<leader>g` (Git), or `<leader>t` (tests) to narrow the helper menu.

## Coding workflow

- Rust uses `rust-analyzer` with all Cargo features, proc macros, Clippy on save,
  `rustfmt`, explicit NixOS `codelldb` wiring, Cargo test integration, and
  `crates.nvim`.
- Python uses `basedpyright`, Ruff diagnostics and formatting, virtualenv
  selection, pytest discovery, and `debugpy`; an active project virtualenv is
  used for debugging before the Nix fallback interpreter.
- `<leader>tr` runs the nearest test, `<leader>tt` runs the file, and `<leader>tT`
  runs the project. `<leader>ts` toggles the test summary.
- `<leader>cf` formats the buffer; `<leader>db` toggles a breakpoint and
  `<leader>dc` starts or continues debugging.
- `<leader>gd` opens the working-tree diff and `<leader>gS` opens the staged diff;
  `<leader>gh` opens current-file history.
- Copilot suggestions appear in Blink completion. Use `<Tab>` to accept the
  selected completion and `:Copilot auth` once per machine to sign in.
- `<leader>a` opens Harpoon; `<leader>cr` performs incremental rename.
- `<leader>oo` opens the project task runner; use it for `just`, Cargo, pytest,
  and repo-defined commands instead of inventing editor-specific build logic.
- `<leader>cs` opens the symbol outline; Treesitter context keeps the current
  function/type visible while navigating large files.
- `<leader>rs` opens structural refactors and `<leader>cn` generates a language-
  appropriate documentation stub.
- `:Neoconf` manages repository-specific LSP settings; keep project policy in
  the repository instead of encoding it globally.
- `<leader>G` opens GitHub workflow tools for issues and pull requests when
  `gh` is available; review remains an explicit human action.

## Per-project overrides

- `.envrc` / `mise.toml` — the toolchain (this is the main lever).
- `.lazy.lua` at a project root — LazyVim reads it for project-specific plugin
  or formatter overrides.

## Gotchas

- **LSP started before direnv loaded** (rare, first buffer of a session): run
  `:LspRestart` to re-spawn against the now-loaded project PATH.
- **Updating plugins is deliberate:** `:Lazy update`, then commit the new
  `lazy-lock.json`. No auto-update nagging is configured.
- **A project tool must actually be installed** for direnv to expose it: run
  `npm install` (JS) or `mise install` (mise.toml) in the project first.
