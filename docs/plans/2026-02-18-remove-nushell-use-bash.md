# Design: Remove Nushell, Switch All Hosts to Bash

**Date:** 2026-02-18
**Scope:** All NixOS hosts (acer-swift, lenovo-21CB001PMX, msi-ms7758, workstation-template) + macOS (work-mac)

## Problem

Nushell has different syntax from bash. LLMs (and most tooling) default to bash. This causes friction when agents or scripts generate shell code — nushell's `extraEnv` blocks require non-standard syntax that is easy to get wrong.

## Decision

Remove nushell entirely from all hosts. Bash becomes the login shell everywhere. Kubectl/git aliases from `modules/core/nushell.nix` are preserved by migrating them to `programs.bash.shellAliases`.

## What Changes

### Shell default and login shell
- `modules/core/system.nix`: change `default = "nushell"` → `"bash"` in the `shell` option
- `hosts/*/variables.nix` (acer-swift, lenovo, msi): remove `shell = "nushell"` lines (they become redundant with the new default)
- `darwin/common.nix`: change `shell = pkgs.nushell` → `shell = pkgs.bash`

### Remove nushell module and imports
- Delete `modules/core/nushell.nix`
- Remove `../../modules/core/nushell.nix` import from:
  - `hosts/acer-swift/home.nix`
  - `hosts/lenovo-21CB001PMX/home.nix`
  - `hosts/msi-ms7758/home.nix`
  - `hosts/workstation-template/home.nix`
  - `home/lukas.nix` (macOS)

### Migrate aliases to bash
- Add `programs.bash.shellAliases` to `modules/core/bash.nix` (new file) or inline in a suitable existing core module, covering the aliases from nushell.nix: `gco`, `k`, `kg`, `kd`, `ka`, `kdel`, `kgp`, `kgs`, `kgd`, `kgn`, `kga`
- Import the bash core module from wherever nushell.nix was previously imported

### Convert nushell extraEnv blocks to bash equivalents
Three modules have nushell extraEnv that need converting to `programs.bash.initExtra`/`profileExtra`:

1. `modules/programs/cli/claude-code/mcp.nix` — token sourcing (SOPS + .env file)
2. `modules/programs/cli/claude-code/default.nix` — workstation env file loading
3. `modules/programs/cli/github-app-auth/default.nix` — GH_TOKEN export (already has bash version; just remove the nushell block)

### neofetch on shell start
`nushell.nix` runs `neofetch` on interactive startup. Equivalent: add `neofetch` call to `programs.bash.initExtra` in the new bash core module, gated by `[ -t 1 ]` (interactive check).

## What Stays the Same

- All `programs.bash.*` config already in place (initExtra, profileExtra, shellAliases)
- Physical host behaviour (same packages, same aliases, same env sourcing)
- Workstation VM behaviour (same agent-env, otel-env, github-app-env sourcing)
- macOS package list unaffected except shell binary

## Files Affected

| File | Change |
|------|--------|
| `modules/core/system.nix` | `default = "bash"` |
| `modules/core/nushell.nix` | **deleted** |
| `modules/core/bash.nix` | **new** — aliases + neofetch |
| `hosts/acer-swift/variables.nix` | remove `shell = "nushell"` |
| `hosts/lenovo-21CB001PMX/variables.nix` | remove `shell = "nushell"` |
| `hosts/msi-ms7758/variables.nix` | remove `shell = "nushell"` |
| `hosts/*/home.nix` (all 4 NixOS) | replace nushell.nix import with bash.nix |
| `home/lukas.nix` | replace nushell.nix import with bash.nix |
| `darwin/common.nix` | `shell = pkgs.bash` |
| `modules/programs/cli/claude-code/mcp.nix` | remove nushell extraEnv block |
| `modules/programs/cli/claude-code/default.nix` | remove nushell extraEnv block |
| `modules/programs/cli/github-app-auth/default.nix` | remove nushell extraEnv block |
