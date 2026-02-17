# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A NixOS + nix-darwin + Home Manager configuration repository using **flake-parts** with a dendritic auto-discovery pattern. Manages Linux desktops, laptops, headless servers, macOS machines, and KubeVirt workstation images from a single flake.

## Build & Deploy Commands

```bash
# Build and apply locally (NixOS)
sudo nixos-rebuild switch --flake .#<hostname>

# Build without applying (dry run)
sudo nixos-rebuild build --flake .#<hostname>

# Validate flake
nix flake check --all-systems --no-write-lock-file

# Build a specific host config (no root needed)
nix build .#nixosConfigurations.<hostname>.config.system.build.toplevel --no-link

# Remote deploy via SSH
nixos-rebuild switch --flake .#<hostname> --target-host lukas@<ip> --sudo --ask-sudo-password

# macOS (nix-darwin)
nix run nix-darwin -- switch --flake .#work-mac   # first time
darwin-rebuild switch --flake .#work-mac           # subsequent

# Workstation images (Justfile)
just build                    # Build qcow2 image
just publish [tag]            # Publish OCI containerDisk to Harbor
just release [tag]            # Build + publish
```

Current hostnames: `acer-swift`, `lenovo-21CB001PMX`, `msi-ms7758`, `workstation-template`

## Architecture

### Flake Entry Point

`flake.nix` is minimal (~49 lines). It recursively auto-imports all `.nix` files from `flake-modules/` using `collectFlakeModules`. The `flake-modules/` directory is numbered for load order:

- `00-flake-parts-modules.nix` — flake-parts setup
- `10-systems.nix` — supported systems
- `20-module-registry.nix` — auto-generates module registries from filesystem
- `30-configurations-options.nix` — typed host declaration options
- `40-outputs-nixos.nix` — transforms declarations into `nixosConfigurations`
- `41-outputs-darwin.nix` — transforms declarations into `darwinConfigurations`
- `hosts/<name>.nix` — per-host distribution declarations

### Module Registry (`20-module-registry.nix`)

Automatically generates `flake.modules` from filesystem conventions:
- `modules/roles/*.nix` → `flake.modules.nixos.role-<name>`
- `hosts/*/home.nix` → `flake.modules.homeManager.host-<dir>`
- `darwin/*.nix` → `flake.modules.darwin.<name>`
- `home/*.nix` → `flake.modules.homeManager.darwin-<name>`

### Host Configuration Flow

Each host follows a 3–4 file pattern in `hosts/<name>/`:

| File | Purpose |
|------|---------|
| `variables.nix` | Plain attrset of host-specific choices (username, roles, desktop, videoDriver, monitors, etc.) |
| `configuration.nix` | NixOS system modules — imports `variables.nix`, sets `sam.profile` |
| `home.nix` | Home Manager config — conditionally imports modules based on roles |
| `hardware-configuration.nix` | Auto-generated hardware scan (physical machines only; omitted for virtual/image targets like `workstation-template`) |

The wiring: `flake-modules/hosts/<name>.nix` reads `variables.nix` and creates a typed `configurations.nixos.<name>` declaration. Then `40-outputs-nixos.nix` resolves roles to modules, injects Stylix/SOPS/Home Manager, and produces the final `nixosConfigurations.<name>`.

### Profile System (`sam.profile`)

Defined in `modules/core/system.nix`. All host metadata lives in `config.sam.profile` — a typed NixOS option submodule. Modules read this instead of using `specialArgs`. Key fields: `username`, `hostname`, `desktop`, `videoDriver`, `monitors`, `roles`, `laptop`, `games`, `lanCidr`, `sshAuthorizedKeys`.

### Roles (`modules/roles/`)

Composable role modules assigned per-host via `variables.nix`:
- **base** — required on every host (enforced by assertion); imports all `modules/core/`
- **desktop** — Hyprland or i3 stack + Catppuccin theme (reads `sam.profile.desktop`)
- **laptop** — laptop-specific overrides
- **homelab-agent** — k3s worker node; disables sleep/suspend
- **homelab-server** — k3s control plane

### Module Layout

```
modules/
├── core/         # System baseline (boot, users, network, services, packages, automation)
├── desktop/      # Desktop stacks: hyprland/ (Wayland), i3/ (X11)
├── hardware/     # GPU drivers (intel, nvidia-kepler, nvidia-modern, amd), thermal
├── homelab/      # k3s (agent/server), sops, flux, workstation-image
├── programs/     # Home Manager programs: cli/, browser/, editor/, terminal/
├── roles/        # Composition roles (see above)
└── themes/       # Catppuccin via Stylix
```

### Secrets

SOPS-nix with age-based encryption. Config in `secrets/.sops.yaml`. Secrets decrypt at boot to `/run/secrets/`. Used for k3s cluster tokens, Cloudflare API keys, etc.

### Key Inputs

nixpkgs (unstable), flake-parts, home-manager, nix-darwin, stylix, sops-nix — all following nixpkgs.

## Conventions

- **No specialArgs**: Host data flows through `sam.profile` typed options, not `specialArgs` pass-through.
- **Desktop polymorphism**: `sam.profile.desktop` drives which desktop stack loads. Hyprland for modern hardware, i3 for legacy.
- **Program selection**: `sam.profile.terminal`, `.browser`, `.editor`, `.shell` select which program modules to import in `home.nix`.
- **User identity**: `lib/users.nix` holds git config and SSH keys, referenced as `sam.userConfig`.
- **Firewall**: LAN CIDR defaults to `192.168.10.0/24` (override via `sam.profile.lanCidr`). SSH is key-only, no root login.
- **stateVersion**: Set to `25.11` in `core/system.nix`.

## Adding a New Host

1. Create `hosts/<name>/` with `variables.nix`, `configuration.nix`, `home.nix`, `hardware-configuration.nix`
2. Create `flake-modules/hosts/<name>.nix` declaring `configurations.nixos.<name>` (reads variables, sets system/username/roles)
3. The module registry auto-discovers the rest
