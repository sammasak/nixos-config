# NixOS Configuration

Personal NixOS + nix-darwin + Home Manager configuration. A work in progress as I learn the Nix ecosystem.

## Goals

- Unified config across Linux desktops, servers, and macOS
- Single user config that adapts to each machine type
- Reproducible, declarative system management
- Learn Nix patterns and best practices along the way

## Current Machines

| Machine | Type | Status |
|---------|------|--------|
| `acer-swift` | Linux laptop (Hyprland) | Active |
| `lenovo-21CB001PMX` | Linux laptop (Hyprland) | Active |
| `work-mac` | macOS (CLI only) | Planned |

## Structure

```
flake.nix                # Entry point, host definitions
├── hosts/               # Per-machine configs
│   ├── acer-swift/
│   │   ├── configuration.nix
│   │   ├── hardware-configuration.nix
│   │   ├── home.nix
│   │   └── variables.nix
│   └── lenovo-21CB001PMX/
│       ├── configuration.nix
│       ├── hardware-configuration.nix
│       ├── home.nix
│       └── variables.nix
├── modules/             # Reusable modules
│   ├── core/            # System baseline (nix, users, services, fonts)
│   ├── desktop/         # Desktop stacks (Hyprland)
│   ├── hardware/        # Hardware drivers
│   ├── programs/        # Home Manager program modules
│   ├── roles/           # Base/desktop/laptop composition
│   └── themes/          # Theme definitions
├── darwin/              # macOS system configuration
│   └── common.nix
├── home/                # Home Manager entrypoints
│   └── lukas.nix        # darwin CLI profile
├── lib/                 # Shared helpers (users, theme)
├── assets/              # Wallpapers and other assets
├── dotfiles/            # Plain config files (symlinked)
├── secrets/             # Secrets (handled out-of-band)
└── tmp/                 # Local comparison/scratch (gitignored)
```

## How It Works

Each host lives in `hosts/<name>/` and provides:

- `variables.nix`: choices for desktop, theme, apps, hardware
- `configuration.nix`: system modules for that host
- `home.nix`: Home Manager modules for that host

[flake.nix](flake.nix) wires `mkHost` to load those files, pass `host`/`user` to modules, and share common building blocks in `modules/`. macOS uses `darwin/common.nix` plus the `home/lukas.nix` CLI profile.

Roles are driven by `variables.nix`:

- `roles = [ "base" "laptop" "desktop" ]` for laptops
- Drop `"desktop"` for headless machines to keep the same shell/CLI baseline without a GUI

## Commands

```bash
# Build and switch (Linux)
sudo nixos-rebuild switch --flake .#acer-swift
sudo nixos-rebuild switch --flake .#lenovo

# Test build without applying
sudo nixos-rebuild build --flake .#acer-swift

# Update all inputs
nix flake update

# macOS (first time - installs nix-darwin)
nix run nix-darwin -- switch --flake .#work-mac

# macOS (subsequent)
darwin-rebuild switch --flake .#work-mac

# Rollback if something breaks
sudo nixos-rebuild switch --rollback

# Garbage collection (manual)
nix-collect-garbage -d
```

## Automation

System auto-updates weekly (Sunday 3 AM), runs garbage collection monthly, and optimizes the store weekly. Configured in `modules/core/automation.nix`.

## Fresh Install (New Laptop)

Boot [NixOS ISO](https://nixos.org/download/#nixos-iso) (GNOME/Plasma for WiFi GUI), then:

```bash
nix-shell -p git
git clone <repo-url> /mnt/home/nixos-config && cd /mnt/home/nixos-config

# Create host config (copy from existing machine)
mkdir -p hosts/<name>
cp /mnt/etc/nixos/hardware-configuration.nix hosts/<name>/
cp hosts/acer-swift/{configuration.nix,home.nix,variables.nix} hosts/<name>/
# Edit variables.nix + configuration.nix, then add the host to flake.nix
```

## Adding a New Machine

1. Create `hosts/<name>/` by copying an existing host
2. Update `variables.nix` (apps, desktop, hardware)
3. Update `configuration.nix` if the hardware/roles differ
4. Add the host entry in [flake.nix](flake.nix)

Use `hosts/acer-swift` and `hosts/lenovo-21CB001PMX` as examples.

## Customization

| What | Where |
|------|-------|
| Theme & colors | [modules/themes/Catppuccin/default.nix](modules/themes/Catppuccin/default.nix) |
| Wallpaper | `assets/wallpapers/` |
| Git credentials | [lib/users.nix](lib/users.nix) |
| VSCode settings | [dotfiles/vscode/](dotfiles/vscode/) |
| Hyprland keybinds | [modules/desktop/hyprland/](modules/desktop/hyprland/) |

## Learning Resources

These have been helpful in understanding Nix:

- [NixOS Manual](https://nixos.org/manual/nixos/stable/)
- [Home Manager Manual](https://nix-community.github.io/home-manager/)
- [nix-darwin](https://github.com/nix-darwin/nix-darwin)
- [Nix Pills](https://nixos.org/guides/nix-pills/) (language fundamentals)
- [Stylix](https://github.com/danth/stylix) (theming)
- [Hyprland Wiki](https://wiki.hyprland.org/)

## Inspiration

This setup is inspired by [Sly-Harvey/NixOS](https://github.com/Sly-Harvey/NixOS). Thanks for sharing a clean, modular reference repo.
