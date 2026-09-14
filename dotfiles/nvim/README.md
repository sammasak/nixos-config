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

- **Home (NixOS):** `.envrc` = `use flake` / devenv → the repo's devshell
  provides `rust-analyzer`, `vtsls`, `svelte-language-server`, etc. Mason is
  **off** (its prebuilt binaries can't run on NixOS); servers come from PATH.
- **Work (no nix):** `.envrc` = `PATH_add node_modules/.bin` + `use mise` →
  the project's own toolchain provides the servers. Mason is **on** as a
  fallback so a repo with *no* project tooling still gets working LSPs.

The only thing that differs between machines is one runtime check in
`lua/plugins/lsp.lua` (`/etc/NIXOS` present → Mason off). Every other file is
byte-identical everywhere. Plugin versions are pinned by `lazy-lock.json`.

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

Home Manager provides neovim, native deps, and the non-project language servers;
this repo supplies the Lua config. See the parent nixos-config for wiring
(`modules/programs/editor/nvim`). Mason auto-disables — nothing else to do.

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
