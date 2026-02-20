# Simplification Migration Guide

**Date:** 2026-02-20

**Commits:** b26443b through 371f788

## Overview

Major architectural refactor simplifying the configuration system by:
- Reducing `sam.profile` from 24 fields to 13 essential fields
- Moving desktop environment from role-based system to NixOS specialisation
- Removing dead code: macOS/nix-darwin infrastructure, i3 desktop environment, LightDM display manager
- Consolidating duplicate Home Manager configurations

## Changes

### sam.profile Fields Removed (14 total)

The following fields were removed from `sam.profile` in `modules/core/system.nix`:

1. **`desktop`** - Moved to specialisation (was: `"hyprland"` or `"i3"`)
2. **`waybarTheme`** - Hardcoded directly in waybar module
3. **`sddmTheme`** - Hardcoded directly in SDDM module
4. **`displayManager`** - Always SDDM now
5. **`defaultWallpaper`** - Per-host configuration, not shared metadata
6. **`terminal`** - Direct imports instead of conditional logic
7. **`browser`** - Direct imports instead of conditional logic
8. **`editor`** - Direct imports instead of conditional logic
9. **`tuiFileManager`** - Direct imports instead of conditional logic
10. **`shell`** - Always bash now (nushell fully removed)
11. **`games`** - Per-host boolean, not needed in shared profile
12. **`hardwareControl`** - Per-host boolean, not needed in shared profile
13. **`fancontrol`** - Per-host boolean, not needed in shared profile
14. **`hwmonModules`** - Per-host configuration, not needed in shared profile

### sam.profile Fields Retained (13 total)

Essential metadata that remains in `sam.profile`:

1. `username` - Primary user for this host
2. `hostname` - System hostname
3. `timezone` - Time zone (default: `"UTC"`)
4. `locale` - Default locale (default: `"en_US.UTF-8"`)
5. `kbdLayout` - Keyboard layout (default: `"us"`)
6. `kbdVariant` - Keyboard layout variant (default: `""`)
7. `consoleKeymap` - Virtual console keymap (default: `"us"`)
8. `videoDriver` - Video driver module selector (default: `"intel"`)
9. `monitors` - Hyprland monitor definitions (default: `[",preferred,auto,1"]`)
10. `laptop` - Whether this host is a laptop (default: `false`)
11. `roles` - Role aspects enabled for this host (default: `["base"]`)
12. `sshAuthorizedKeys` - Optional host-specific SSH authorized key override (default: `[]`)
13. `lanCidr` - Trusted LAN CIDR for firewall rules (default: `"192.168.10.0/24"`)

### Desktop Specialisation

Desktop environment is now a boot-time specialisation instead of a role.

**Old approach (role-based):**
```nix
# variables.nix
{
  desktop = "hyprland";
  roles = [ "base" "desktop" "laptop" ];
  # ...
}
```

**New approach (specialisation):**
```nix
# configuration.nix
{
  specialisation.desktop.configuration = {
    imports = [ ../../modules/specialisations/desktop.nix ];
  };
}
```

The `modules/specialisations/desktop.nix` module bundles:
- Hyprland (Wayland compositor)
- SDDM (display manager)
- Catppuccin theme (via Stylix)
- GUI applications

**Affected hosts:**
- `acer-swift` - Has desktop specialisation
- `lenovo-21CB001PMX` - Has desktop specialisation
- `msi-ms7758` - Headless only (no specialisation)
- `workstation-template` - Headless only (no specialisation)

### Dead Code Removed

#### macOS/nix-darwin Infrastructure

All macOS support has been removed (commit b26443b):

**Deleted files:**
- `flake-modules/41-outputs-darwin.nix` - Darwin output builder
- `flake-modules/hosts/work-mac.nix` - macOS host declaration
- `home/lukas.nix` - Darwin-specific Home Manager config
- `darwin/common.nix` - Darwin system configuration

**Modified files:**
- `flake-modules/10-systems.nix` - Removed `aarch64-darwin` and `x86_64-darwin`
- `flake-modules/20-module-registry.nix` - Removed darwin module auto-discovery
- `flake-modules/30-configurations-options.nix` - Removed `configurations.darwin` option
- `flake.nix` - Removed nix-darwin input
- `CLAUDE.md` - Removed darwin documentation
- `README.md` - Removed darwin build commands

**Lines removed:** ~195

#### i3 Desktop Environment

The legacy i3 desktop environment has been removed (commit c19f390):

**Deleted files:**
- `modules/desktop/i3/default.nix` - i3 system configuration (33 lines)
- `modules/desktop/i3/home.nix` - i3 Home Manager config (158 lines)

**Modified files:**
- `modules/roles/desktop.nix` - Removed i3 conditional imports
- `modules/core/sddm.nix` - Removed i3 session option
- `hosts/msi-ms7758/variables.nix` - Changed desktop from `"i3"` to `"none"`

**Lines removed:** ~207

#### LightDM Display Manager

The unused LightDM display manager has been removed (commit 6a5f238):

**Deleted files:**
- `modules/core/lightdm.nix` - LightDM configuration (14 lines)

**Modified files:**
- `modules/core/system.nix` - Removed LightDM import

**Lines removed:** ~15

## How to Use

### Booting into Desktop Mode

For hosts with desktop specialisation (`acer-swift`, `lenovo-21CB001PMX`):

1. **At boot time**, the systemd-boot menu will show two entries:
   - `NixOS` - Default server mode (headless, no GUI)
   - `NixOS (desktop)` - Desktop mode with Hyprland + SDDM

2. **Select the desktop entry** using arrow keys and press Enter

3. **SDDM will start** and present a graphical login screen

4. **Log in** with your user credentials

5. **Hyprland will launch** with the Catppuccin theme

**To make desktop the default:**
Currently not implemented. The default boot entry is always the base system. To boot into desktop mode, you must select it manually from the boot menu each time.

### Server Mode (Default)

The default boot configuration is headless server mode, which includes:

**System services:**
- SSH server (key-only authentication)
- k3s agent or server (for homelab hosts)
- GPG agent with SSH support
- systemd-resolved (DNS)
- Tailscale (optional, per-host)

**Shell environment:**
- Bash (default shell)
- Nushell available but not default
- Claude Code with MCP servers
- Git, tmux, htop, etc.

**No GUI components:**
- No display manager
- No window manager
- No desktop applications
- Minimal resource usage

### Migration Steps for Existing Hosts

If you have a host that was previously configured with the old system:

1. **Update `variables.nix`:**
   - Remove deprecated fields (`desktop`, `terminal`, `browser`, `editor`, `shell`, `games`, etc.)
   - Keep only the 13 essential fields listed above

2. **Update `configuration.nix`:**
   - Add desktop specialisation if you want GUI mode:
     ```nix
     specialisation.desktop.configuration = {
       imports = [ ../../modules/specialisations/desktop.nix ];
     };
     ```

3. **Update `home.nix`:**
   - Replace with shared module import:
     ```nix
     { ... }:
     {
       imports = [ ../../modules/home-manager/shared.nix ];
     }
     ```
   - The shared module auto-detects desktop mode via `config.programs.hyprland.enable`

4. **Rebuild:**
   ```bash
   sudo nixos-rebuild switch --flake .#<hostname>
   ```

5. **Reboot:**
   ```bash
   sudo reboot
   ```

6. **Select desktop from boot menu** if you want GUI mode

## Technical Details

### Specialisation Implementation

The desktop specialisation uses NixOS's built-in `specialisation` feature:

```nix
# In configuration.nix
specialisation.desktop.configuration = {
  imports = [ ../../modules/specialisations/desktop.nix ];
};
```

This creates a separate system profile that:
- **Inherits** all base system configuration
- **Adds** desktop-specific modules on top
- **Creates** a separate boot menu entry
- **Shares** the same `/nix/store` paths (no duplication)

### Home Manager Integration

The new shared Home Manager module (`modules/home-manager/shared.nix`) detects desktop mode automatically:

```nix
isDesktop = config.programs.hyprland.enable or false;
```

This replaces the old approach of checking `sam.profile.desktop` and allows the same `home.nix` to work in both server and desktop modes.

### Role System Changes

The `desktop` role is now deprecated but remains for backward compatibility:

- **Old:** `roles = [ "base" "desktop" "laptop" ];`
- **New:** `roles = [ "base" "laptop" ];` + desktop specialisation

The `modules/roles/desktop.nix` file still exists but only imports themes and SDDM. The actual desktop stack (Hyprland) is loaded via specialisation.

## Rationale

### Why Remove These Fields?

**Single-use fields** (`terminal`, `browser`, `editor`, `shell`):
- Only used for conditional imports in `home.nix`
- Direct imports are simpler and more explicit
- No runtime benefit to indirection

**Per-host booleans** (`games`, `hardwareControl`, `fancontrol`, `hwmonModules`):
- Only used by one host each
- Better placed directly in host `configuration.nix`
- Clutters the shared profile schema

**Theme fields** (`waybarTheme`, `sddmTheme`, `defaultWallpaper`):
- Hardcoding in modules is simpler (all hosts use Catppuccin)
- Per-host customization can use `mkForce` if needed

**Desktop field**:
- Moved to specialisation for cleaner architecture
- Allows boot-time choice instead of rebuild-time choice
- Reduces profile field count

### Why Specialisation Instead of Role?

**Benefits:**
1. **Boot-time selection** - No rebuild needed to switch modes
2. **Cleaner separation** - Server config doesn't include desktop code
3. **Resource efficiency** - Desktop packages only loaded when needed
4. **Better for homelab** - k3s nodes default to headless, boot into GUI when needed

**Tradeoffs:**
- Requires manual boot menu selection (no way to set default to desktop)
- Slightly larger boot menu
- Less discoverable than role system

### Why Remove macOS?

The `work-mac` host was unused and unmaintained. Removing it:
- Simplifies the flake structure
- Removes ~200 lines of dead code
- Eliminates nix-darwin as a dependency
- Focuses the repo on NixOS-only hosts

If macOS support is needed again, it can be re-added as a separate flake or repo.

### Why Remove i3?

All hosts now use Hyprland (Wayland). The i3 (X11) config was:
- Only used by `msi-ms7758` (which is now headless)
- Outdated and unmaintained
- Incompatible with modern Wayland workflows

### Why Remove LightDM?

SDDM is the default and only display manager used across all hosts. LightDM was:
- Never actually enabled on any host
- Redundant code path

## Future Improvements

### Possible Enhancements

1. **Default boot entry:**
   - Add option to make desktop the default boot entry
   - Currently always boots to server mode

2. **Gaming specialisation:**
   - Create `specialisation.gaming.configuration` for Steam, Lutris, etc.
   - Keep gaming software out of desktop mode

3. **Per-host specialisations:**
   - Allow hosts to define multiple specialisations
   - Example: `workstation-template` could add desktop specialisation for development

4. **Shared specialisation modules:**
   - Factor out common specialisation patterns
   - Reuse across multiple hosts

### Non-Goals

These are intentionally not implemented:

- **Runtime switching** - Specialisations require reboot
- **Conditional desktop loading** - Desktop is always available (if specialisation exists)
- **Per-user specialisations** - NixOS specialisations are system-wide only

## References

- **Planning document:** `docs/plans/2026-02-20-simplify-sam-profile-and-add-desktop-specialisation.md`
- **NixOS specialisations:** https://nixos.wiki/wiki/Specialisation
- **Commit range:** b26443b..371f788 (20 commits)
- **Lines removed:** ~622 total (macOS: 195, i3: 207, LightDM: 15, other: ~205)

## Rollback Instructions

If you need to revert to the old system:

```bash
# Check out the commit before the refactor
git checkout a313ce6

# Rebuild
sudo nixos-rebuild switch --flake .#<hostname>

# Reboot
sudo reboot
```

Note: This will restore macOS, i3, and LightDM support along with the old `sam.profile` schema.
