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
| `work-mac` | macOS (CLI only) | Planned |

## Structure

```
flake.nix              # Entry point, machine definitions
├── nixos/             # NixOS system configuration
│   ├── common.nix     # Base Linux (nix settings, user, locale)
│   ├── desktop.nix    # GUI environment (Hyprland, PipeWire)
│   └── laptop.nix     # Laptop-specific (power, touchpad)
├── darwin/            # macOS system configuration
│   └── common.nix     # System preferences (Dock, Finder)
├── home/              # Home Manager user configuration
│   └── lukas.nix      # My user config (adapts via desktop flag)
├── modules/           # Reusable configuration modules
│   ├── shell/         # CLI: nushell, starship, git, cli-tools
│   ├── dev/           # Development: vscode
│   ├── desktop/       # GUI: hyprland, kitty, waybar, etc.
│   ├── fonts.nix      # Font packages
│   └── stylix.nix     # Theme configuration
├── hosts/             # Per-machine hardware configuration
├── lib/               # Helper files (users.nix, theme.nix)
├── assets/            # Wallpapers and other assets
└── dotfiles/          # Plain config files (symlinked)
```

## How It Works

The `mkHome` helper in [flake.nix](flake.nix) passes a `desktop` flag to the user config. When `desktop = true`, GUI modules (Hyprland, kitty, waybar, etc.) are included. When `false`, only CLI tools are loaded.

This keeps one user config file that works on desktops, servers, and macOS.

## Commands

```bash
# Build and switch (Linux)
sudo nixos-rebuild switch --flake .#acer-swift

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
```

## Fresh Install (New Laptop)

Boot [NixOS ISO](https://nixos.org/download/#nixos-iso) (GNOME/Plasma for WiFi GUI), then:

```bash
nix-shell -p git
git clone <repo-url> /mnt/home/nixos-config && cd /mnt/home/nixos-config

# Create host config (copy from existing machine)
mkdir -p hosts/<name>
cp /mnt/etc/nixos/hardware-configuration.nix hosts/<name>/
cp hosts/acer-swift/default.nix hosts/<name>/  # edit stateVersion
# Add machine to flake.nix (copy acer-swift block, change name)
```

## Adding a New Machine

1. Create `hosts/<name>/default.nix` with hardware configuration
2. Add entry to [flake.nix](flake.nix):
   - **Linux desktop**: Include `nixos/common.nix`, `nixos/desktop.nix`, and `mkHome { desktop = true; }`
   - **Linux server**: Include `nixos/common.nix` and `mkHome { desktop = false; }`
   - **macOS**: Include `darwin/common.nix` and `mkHome { desktop = false; }`

See existing configurations in `flake.nix` for examples.

## Customization

| What | Where |
|------|-------|
| Theme & colors | [modules/stylix.nix](modules/stylix.nix) |
| Wallpaper | `assets/wallpapers/wallpaper.jpg` |
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

