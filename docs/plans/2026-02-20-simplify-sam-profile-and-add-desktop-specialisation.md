# Simplify sam.profile & Add Desktop Specialisation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Simplify `sam.profile` from 24 fields to 10 essential fields, remove dead code (macOS, i3, LightDM), and introduce NixOS specialisation so all capable hosts can boot into either server mode (default) or desktop mode (GUI).

**Architecture:**
- Move desktop environment from role-based system to NixOS specialisation pattern
- Consolidate 3 duplicate home.nix files into one shared module
- Remove single-use fields from `sam.profile` (terminal, browser, editor, displayManager, desktop themes)
- Delete dead code paths: macOS/nix-darwin support, i3 desktop, LightDM display manager
- Keep only essential metadata in `sam.profile`: username, hostname, timezone, locale, kbd config, videoDriver, monitors, laptop, roles, ssh, lanCidr

**Tech Stack:** NixOS specialisation, flake-parts dendritic pattern, Home Manager

**Hosts Affected:**
- acer-swift: Intel laptop, gets desktop specialisation
- lenovo-21CB001PMX: Intel laptop, gets desktop specialisation
- msi-ms7758: Legacy NVIDIA Kepler, stays headless (no specialisation)
- workstation-template: VM image, stays headless

---

## Phase 1: Delete Dead Code

### Task 1.1: Remove macOS/nix-darwin Infrastructure

**Files:**
- Delete: `flake-modules/41-outputs-darwin.nix`
- Delete: `flake-modules/hosts/work-mac.nix`
- Delete: `home/` (entire directory - darwin-specific Home Manager modules)
- Modify: `flake-modules/20-module-registry.nix` (remove darwin auto-discovery)
- Modify: `flake-modules/10-systems.nix` (remove darwin systems)
- Modify: `CLAUDE.md` (remove darwin references)

**Step 1: Delete darwin output module**

```bash
rm flake-modules/41-outputs-darwin.nix
```

**Step 2: Delete darwin host declaration**

```bash
rm flake-modules/hosts/work-mac.nix
```

**Step 3: Delete darwin home-manager modules**

```bash
rm -rf home/
```

**Step 4: Remove darwin from module registry**

Edit `flake-modules/20-module-registry.nix`, remove lines ~60-75 (darwin module discovery):

```nix
# DELETE THIS SECTION:
darwinModules =
  let
    darwinFiles = lib.fileset.toList (
      lib.fileset.fileFilter (file: file.hasExt "nix" && file.name != "default.nix") ../darwin
    );
  in
  builtins.listToAttrs (
    map (file: {
      name = lib.removeSuffix ".nix" file.name;
      value = ../darwin/${file.name};
    }) darwinFiles
  );

darwinHomeModules =
  let
    homeFiles = lib.fileset.toList (lib.fileset.fileFilter (file: file.hasExt "nix") ../home);
  in
  builtins.listToAttrs (
    map (file: {
      name = "darwin-${lib.removeSuffix ".nix" file.name}";
      value = ../home/${file.name};
    }) homeFiles
  );
```

And remove from the merged attrset at the bottom (remove `// darwinModules // darwinHomeModules`).

**Step 5: Remove darwin systems**

Edit `flake-modules/10-systems.nix`, change to:

```nix
{ ... }:
{
  systems = [ "x86_64-linux" ];
}
```

**Step 6: Update CLAUDE.md**

Remove macOS-related sections (lines about `nix-darwin`, `darwin-rebuild`, darwin configurations).

**Step 7: Verify flake builds**

```bash
nix flake check --all-systems --no-write-lock-file
```

Expected: No darwin-related errors, clean output.

**Step 8: Commit**

```bash
git add -A
git commit -m "refactor: remove macOS/nix-darwin infrastructure (unused)"
```

---

### Task 1.2: Remove i3 Desktop Environment

**Files:**
- Delete: `modules/desktop/i3/` (entire directory)
- Modify: `modules/roles/desktop.nix`
- Modify: `flake-modules/20-module-registry.nix` (remove from supported list if needed)

**Step 1: Delete i3 modules**

```bash
rm -rf modules/desktop/i3/
```

**Step 2: Update desktop role**

Edit `modules/roles/desktop.nix`:

```nix
# Desktop role (display manager + theme + desktop stack)
{ ... }:
{
  imports = [
    ../core/sddm.nix
    ../themes/Catppuccin
    ../desktop/hyprland
  ];
}
```

Remove the `assertions` block and `supported` list entirely (only Hyprland remains).

**Step 3: Verify no i3 references remain**

```bash
grep -r "i3" modules/ hosts/ flake-modules/ --include="*.nix"
```

Expected: Only false positives (i386, etc.), no actual i3 desktop references.

**Step 4: Commit**

```bash
git add -A
git commit -m "refactor: remove i3 desktop environment (legacy, unused)"
```

---

### Task 1.3: Remove LightDM Display Manager

**Files:**
- Delete: `modules/core/lightdm.nix`

**Step 1: Delete LightDM module**

```bash
rm modules/core/lightdm.nix
```

**Step 2: Verify no lightdm references remain**

```bash
grep -ri "lightdm" modules/ hosts/ --include="*.nix"
```

Expected: No matches.

**Step 3: Commit**

```bash
git add -A
git commit -m "refactor: remove LightDM display manager (unused, SDDM is default)"
```

---

### Task 1.4: Delete Temporary Bloat Files

**Files:**
- Delete: `/tmp/NixOS/` (211 MB of abandoned dev shells)

**Step 1: Remove temporary directory**

```bash
rm -rf /tmp/NixOS/
```

**Step 2: Verify deletion**

```bash
ls -lh /tmp/ | grep NixOS
```

Expected: No output (directory gone).

**Note:** No commit needed (not tracked in git).

---

### Task 1.5: Complete Nushell Removal

**Files:**
- Verify cleanup from recent commits is complete
- Search for any remaining nushell references

**Step 1: Search for remaining nushell references**

```bash
grep -ri "nushell\|nu " modules/ hosts/ flake-modules/ lib/ --include="*.nix"
```

**Step 2: If found, remove them**

(Implementation depends on what's found - manual cleanup)

**Step 3: Verify bash is default shell everywhere**

```bash
grep -r "shell.*=" hosts/*/variables.nix modules/core/users.nix
```

Expected: All references point to bash.

**Step 4: Commit if changes made**

```bash
git add -A
git commit -m "refactor: complete nushell removal (migrated to bash)"
```

---

## Phase 2: Simplify sam.profile Schema

### Task 2.1: Reduce sam.profile Fields

**Files:**
- Modify: `modules/core/system.nix:8-177` (options.sam.profile)

**Step 1: Create backup**

```bash
cp modules/core/system.nix modules/core/system.nix.backup
```

**Step 2: Edit sam.profile options**

Edit `modules/core/system.nix`, replace the `options.sam.profile` block (lines 9-177) with:

```nix
  profile = mkOption {
    description = "Host profile metadata used by reusable modules.";
    type = types.submodule {
      options = {
        username = mkOption {
          type = types.str;
          description = "Primary user for this host.";
        };

        hostname = mkOption {
          type = types.str;
          description = "System hostname.";
        };

        timezone = mkOption {
          type = types.str;
          default = "UTC";
          description = "Time zone.";
        };

        locale = mkOption {
          type = types.str;
          default = "en_US.UTF-8";
          description = "Default locale.";
        };

        kbdLayout = mkOption {
          type = types.str;
          default = "us";
          description = "Keyboard layout.";
        };

        kbdVariant = mkOption {
          type = types.str;
          default = "";
          description = "Keyboard layout variant.";
        };

        consoleKeymap = mkOption {
          type = types.str;
          default = "us";
          description = "Virtual console keymap.";
        };

        videoDriver = mkOption {
          type = types.str;
          default = "intel";
          description = "Video driver module selector (intel, nvidia-kepler, nvidia-modern, amd).";
        };

        monitors = mkOption {
          type = types.listOf types.str;
          default = [ ",preferred,auto,1" ];
          description = "Hyprland monitor definitions (name,resolution,position,scale).";
        };

        laptop = mkOption {
          type = types.bool;
          default = false;
          description = "Whether this host is a laptop.";
        };

        roles = mkOption {
          type = types.listOf types.str;
          default = [ "base" ];
          description = "Role aspects enabled for this host.";
        };

        sshAuthorizedKeys = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Optional host-specific SSH authorized key override.";
        };

        lanCidr = mkOption {
          type = types.str;
          default = "192.168.10.0/24";
          description = "Trusted LAN CIDR for host-level firewall rules.";
        };
      };
    };
    default = { };
  };
```

**Removed fields:**
- `desktop` (moving to specialisation)
- `waybarTheme` (hardcoded in waybar module)
- `sddmTheme` (hardcoded in sddm module)
- `displayManager` (always sddm)
- `defaultWallpaper` (per-host, not shared)
- `terminal`, `browser`, `editor`, `tuiFileManager` (direct imports)
- `shell` (always bash now)
- `games`, `hardwareControl`, `fancontrol`, `hwmonModules` (per-host booleans)

**Step 3: Remove environment.variables profile.desktop check**

In same file, around line 274, change:

```nix
environment.variables =
  {
    XDG_CACHE_HOME = "$HOME/.cache";
    XDG_CONFIG_HOME = "$HOME/.config";
    XDG_DATA_HOME = "$HOME/.local/share";
    XDG_BIN_HOME = "$HOME/.local/bin";
    PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
    # Prefer Wayland for Electron apps when desktop specialisation is active
    NIXOS_OZONE_WL = "1";
  };
```

Remove the conditional `lib.optionalAttrs (profile.desktop == "hyprland")` wrapper - just set NIXOS_OZONE_WL always (harmless on non-Wayland).

**Step 4: Verify syntax**

```bash
nix eval .#nixosConfigurations.workstation-template.config.sam.profile --json
```

Expected: JSON output with only the 13 retained fields.

**Step 5: Commit**

```bash
git add modules/core/system.nix
git commit -m "refactor: simplify sam.profile from 24 to 13 essential fields"
```

---

### Task 2.2: Update Host variables.nix Files

**Files:**
- Modify: `hosts/acer-swift/variables.nix`
- Modify: `hosts/lenovo-21CB001PMX/variables.nix`
- Modify: `hosts/msi-ms7758/variables.nix`
- Modify: `hosts/workstation-template/variables.nix`

**Step 1: Update acer-swift/variables.nix**

```nix
# Host-specific variables for acer-swift
{
  # System
  username = "lukas";
  hostname = "acer-swift";
  timezone = "Europe/Stockholm";
  locale = "en_US.UTF-8";
  kbdLayout = "se";
  kbdVariant = "";
  consoleKeymap = "sv-latin1";

  # Hardware
  videoDriver = "intel";
  monitors = [
    "DP-1,3840x2160@60,1920x0,1.5"
    "eDP-1,preferred,0x0,1"
  ];

  # Features
  laptop = true;

  # Roles
  roles = [ "base" "laptop" "homelab-agent" ];
}
```

Removed: desktop, waybarTheme, sddmTheme, defaultWallpaper, terminal, browser, editor, tuiFileManager, games.

**Step 2: Update lenovo-21CB001PMX/variables.nix**

```nix
# Host-specific variables for lenovo-21CB001PMX
{
  # System
  username = "lukas";
  hostname = "lenovo-21CB001PMX";
  timezone = "Europe/Stockholm";
  locale = "en_US.UTF-8";
  kbdLayout = "se";
  kbdVariant = "";
  consoleKeymap = "sv-latin1";

  # Hardware
  videoDriver = "intel";
  monitors = [
    "eDP-1,preferred,0x0,1"
  ];

  # Features
  laptop = true;

  # Roles
  roles = [ "base" "laptop" "homelab-server" ];
}
```

**Step 3: Update msi-ms7758/variables.nix**

```nix
# Host-specific variables for msi-ms7758
{
  # System
  username = "lukas";
  hostname = "msi-ms7758";
  timezone = "Europe/Stockholm";
  locale = "en_US.UTF-8";
  kbdLayout = "se";
  kbdVariant = "";
  consoleKeymap = "sv-latin1";

  # Hardware
  videoDriver = "nvidia-kepler";
  monitors = [ ",preferred,auto,1" ];

  # Roles
  roles = [ "base" "homelab-agent" ];
}
```

**Step 4: Verify workstation-template/variables.nix**

Should already be minimal. Confirm:

```nix
{
  username = "lukas";
  hostname = "workstation-template";
  roles = [ "base" ];
  lanCidr = "192.168.10.0/24";
}
```

**Step 5: Test build**

```bash
nix build .#nixosConfigurations.acer-swift.config.system.build.toplevel --no-link
```

Expected: Build succeeds (may fail on removed fields - that's next phase).

**Step 6: Commit**

```bash
git add hosts/*/variables.nix
git commit -m "refactor: remove obsolete fields from host variables"
```

---

## Phase 3: Create Desktop Specialisation

### Task 3.1: Create Desktop Specialisation Module

**Files:**
- Create: `modules/specialisations/desktop.nix`

**Step 1: Create specialisations directory**

```bash
mkdir -p modules/specialisations
```

**Step 2: Create desktop specialisation module**

Create `modules/specialisations/desktop.nix`:

```nix
# Desktop specialisation (boot-time GUI mode)
# Adds Hyprland, SDDM, themes, and GUI applications to base server config.
{ pkgs, ... }:
{
  imports = [
    ../desktop/hyprland
    ../core/sddm.nix
    ../themes/Catppuccin
  ];

  # Specialisation metadata
  specialisation.desktop.inheritParentConfig = true;

  # Enable X server for compatibility (some apps need it)
  services.xserver.enable = true;

  # GUI applications (installed only in desktop mode)
  environment.systemPackages = with pkgs; [
    # These will be moved from core packages later
  ];
}
```

**Step 3: Commit**

```bash
git add modules/specialisations/desktop.nix
git commit -m "feat: add desktop specialisation module for boot-time GUI mode"
```

---

### Task 3.2: Update SDDM Module to Remove Conditionals

**Files:**
- Modify: `modules/core/sddm.nix`

**Step 1: Simplify SDDM module**

Edit `modules/core/sddm.nix`, remove conditionals (SDDM is always enabled in desktop specialisation):

```nix
# SDDM display manager (always enabled in desktop specialisation)
{ config, pkgs, ... }:
let
  sddmTheme = "astronaut";  # Hardcoded default
  sddm-astronaut = pkgs.sddm-astronaut.override {
    embeddedTheme = sddmTheme;
    themeConfig = {
      PartialBlur = "false";
      FormPosition = "center";
    };
  };
  sddmDependencies = [
    sddm-astronaut
    pkgs.kdePackages.qtsvg
    pkgs.kdePackages.qtmultimedia
    pkgs.kdePackages.qtvirtualkeyboard
  ];
in
{
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;  # Hyprland is Wayland
    enableHidpi = true;
    autoNumlock = true;
    package = pkgs.kdePackages.sddm;
    extraPackages = sddmDependencies;
    settings.Theme.CursorTheme = "Bibata-Modern-Classic";
    theme = "sddm-astronaut-theme";
  };

  environment.systemPackages = sddmDependencies ++ [ pkgs.bibata-cursors ];
}
```

**Step 2: Commit**

```bash
git add modules/core/sddm.nix
git commit -m "refactor: simplify SDDM module (remove conditionals, hardcode Hyprland/Wayland)"
```

---

### Task 3.3: Update Hyprland Module to Remove Conditionals

**Files:**
- Modify: `modules/desktop/hyprland/default.nix`

**Step 1: Read current Hyprland module**

```bash
head -20 modules/desktop/hyprland/default.nix
```

**Step 2: Remove mkIf conditional**

Edit `modules/desktop/hyprland/default.nix`, change line 4 from:

```nix
config = lib.mkIf (config.sam.profile.desktop == "hyprland") {
```

To just:

```nix
{
```

Remove the wrapping `config = lib.mkIf ...` entirely, keeping just the content.

**Step 3: Verify syntax**

```bash
nix eval .#nixosConfigurations.acer-swift.config.programs.hyprland.enable
```

Expected: Will error (not yet wired up), but syntax should be valid.

**Step 4: Commit**

```bash
git add modules/desktop/hyprland/default.nix
git commit -m "refactor: remove conditional from Hyprland module (now in specialisation)"
```

---

### Task 3.4: Create Shared Home Manager Module

**Files:**
- Create: `modules/home/default.nix`
- Modify: `flake-modules/40-outputs-nixos.nix` (change home-manager imports)

**Step 1: Create shared home module directory**

```bash
mkdir -p modules/home
```

**Step 2: Create shared home.nix**

Create `modules/home/default.nix`:

```nix
# Shared Home Manager configuration for all hosts
{ lib, osConfig, ... }:
let
  profile = osConfig.sam.profile;
  roles = profile.roles;
  hasDesktop = builtins.elem "desktop" roles;

  # Base imports for all hosts
  baseImports = [
    ../core/bash.nix
    ../core/starship.nix
    ../programs/cli/git
    ../programs/cli/cli-tools
  ];

  # Desktop imports (when desktop role present)
  # Note: After specialisation refactor, this will check specialisation state
  desktopImports = lib.optionals hasDesktop [
    ../desktop/hyprland/home.nix
    ../programs/terminal/kitty
    ../programs/browser/firefox
    ../programs/editor/vscode
  ];
in
{
  home.stateVersion = "25.11";
  imports = baseImports ++ desktopImports;
}
```

**Step 3: Update flake module registry**

Edit `flake-modules/20-module-registry.nix`, add home module discovery:

```nix
# Around line 50, after nixosRoleModules:

homeModules = {
  shared = ../modules/home/default.nix;
};
```

Then in the final merge (around line 80), add `homeManager = homeModules;`.

**Step 4: Update flake outputs to use shared home**

Edit `flake-modules/40-outputs-nixos.nix`, line 50-52:

```nix
users.${username} =
  config.flake.modules.homeManager.shared
  or (throw "Missing shared home-manager module");
```

Replace the host-specific lookup with `shared`.

**Step 5: Delete old per-host home.nix files**

```bash
rm hosts/acer-swift/home.nix
rm hosts/lenovo-21CB001PMX/home.nix
rm hosts/msi-ms7758/home.nix
```

**Step 6: Update module registry to remove host-specific home discovery**

Edit `flake-modules/20-module-registry.nix`, remove the `homeManagerModules` section (around lines 30-45) that auto-discovers `hosts/*/home.nix`.

**Step 7: Test build**

```bash
nix build .#nixosConfigurations.acer-swift.config.home-manager.users.lukas.home.stateVersion --no-link
```

Expected: Returns "25.11".

**Step 8: Commit**

```bash
git add modules/home/default.nix flake-modules/ hosts/
git commit -m "refactor: consolidate duplicate home.nix files into shared module"
```

---

### Task 3.5: Wire Desktop Specialisation Into Host Configs

**Files:**
- Modify: `hosts/acer-swift/configuration.nix`
- Modify: `hosts/lenovo-21CB001PMX/configuration.nix`
- NOT modifying: `msi-ms7758` (stays headless)
- NOT modifying: `workstation-template` (stays headless)

**Step 1: Add specialisation to acer-swift**

Edit `hosts/acer-swift/configuration.nix`, add after line 14 (after `sam.secrets.enable = true;`):

```nix
  # Desktop specialisation (boot menu option for GUI mode)
  specialisation.desktop.configuration = {
    imports = [ ../../modules/specialisations/desktop.nix ];
  };
```

**Step 2: Add specialisation to lenovo-21CB001PMX**

Edit `hosts/lenovo-21CB001PMX/configuration.nix`, add same block after secrets config.

**Step 3: Remove desktop role from both hosts**

Edit `hosts/acer-swift/variables.nix`:

```nix
roles = [ "base" "laptop" "homelab-agent" ];  # Remove "desktop"
```

Edit `hosts/lenovo-21CB001PMX/variables.nix`:

```nix
roles = [ "base" "laptop" "homelab-server" ];  # Remove "desktop"
```

**Step 4: Test build with specialisation**

```bash
nix build .#nixosConfigurations.acer-swift.config.system.build.toplevel --no-link
```

Expected: Build succeeds with specialisation.desktop in output.

**Step 5: Verify specialisation exists**

```bash
nix eval .#nixosConfigurations.acer-swift.config.specialisation --apply builtins.attrNames
```

Expected: `[ "desktop" ]`

**Step 6: Commit**

```bash
git add hosts/acer-swift/ hosts/lenovo-21CB001PMX/
git commit -m "feat: add desktop specialisation to Intel laptop hosts (acer-swift, lenovo)"
```

---

### Task 3.6: Update Desktop Role (Remove Imports)

**Files:**
- Modify: `modules/roles/desktop.nix`

Since desktop is now a specialisation, the desktop role is obsolete. However, we need to handle transition.

**Step 1: Comment out desktop role contents**

Edit `modules/roles/desktop.nix`:

```nix
# Desktop role (DEPRECATED - desktop is now a specialisation)
# This role is kept temporarily for backward compatibility but does nothing.
# Remove this file after confirming all hosts use specialisation pattern.
{ ... }:
{
  # Intentionally empty - desktop functionality moved to modules/specialisations/desktop.nix
}
```

**Step 2: Remove desktop role from registry**

Eventually we'll delete this file entirely, but keep it empty for now to avoid breaking builds.

**Step 3: Commit**

```bash
git add modules/roles/desktop.nix
git commit -m "refactor: deprecate desktop role (moved to specialisation)"
```

---

## Phase 4: Fix Module Dependencies

### Task 4.1: Update Packages Module

**Files:**
- Modify: `modules/core/packages.nix`

**Step 1: Check current profile field usage**

```bash
grep "sam.profile" modules/core/packages.nix
```

Current usage (line 6): `isHyprland = config.sam.profile.desktop == "hyprland";`

**Step 2: Remove desktop field check**

Edit `modules/core/packages.nix`, remove line 6 and any references to `isHyprland`.

If Hyprland-specific packages exist, they should move to `modules/specialisations/desktop.nix`.

**Step 3: Verify package list**

```bash
nix eval .#nixosConfigurations.acer-swift.config.environment.systemPackages --apply "pkgs: builtins.length pkgs"
```

Expected: Number of packages (should not error).

**Step 4: Commit**

```bash
git add modules/core/packages.nix
git commit -m "refactor: remove desktop field check from packages module"
```

---

### Task 4.2: Update Home Manager Desktop Imports

**Files:**
- Modify: `modules/home/default.nix`

Currently home.nix checks `hasDesktop` role. With specialisation, we need a different approach.

**Step 1: Update desktop detection**

Edit `modules/home/default.nix`:

```nix
# Shared Home Manager configuration for all hosts
{ lib, osConfig, config, ... }:
let
  profile = osConfig.sam.profile;

  # Detect if we're in desktop specialisation mode
  # In specialisation, hyprland will be enabled
  isDesktopMode = osConfig.programs.hyprland.enable or false;

  # Base imports for all hosts
  baseImports = [
    ../core/bash.nix
    ../core/starship.nix
    ../programs/cli/git
    ../programs/cli/cli-tools
  ];

  # Desktop imports (when in desktop specialisation)
  desktopImports = lib.optionals isDesktopMode [
    ../desktop/hyprland/home.nix
    ../programs/terminal/kitty
    ../programs/browser/firefox
    ../programs/editor/vscode
  ];
in
{
  home.stateVersion = "25.11";
  imports = baseImports ++ desktopImports;
}
```

**Step 2: Verify logic**

```bash
nix eval .#nixosConfigurations.acer-swift.config.programs.hyprland.enable
nix eval .#nixosConfigurations.acer-swift.config.specialisation.desktop.configuration.programs.hyprland.enable
```

Expected: `false` for base, `true` for specialisation.

**Step 3: Commit**

```bash
git add modules/home/default.nix
git commit -m "refactor: detect desktop mode via hyprland.enable instead of role"
```

---

### Task 4.3: Fix Waybar and Desktop Home Modules

**Files:**
- Modify: `modules/desktop/hyprland/home.nix` (if it uses profile.terminal, profile.browser)

**Step 1: Check for profile field usage in home.nix**

```bash
grep "profile\." modules/desktop/hyprland/home.nix
```

**Step 2: Hardcode terminal/browser in keybindings**

Edit `modules/desktop/hyprland/home.nix`, replace:

```nix
"$mod, Return, exec, ${profile.terminal}"
"$mod, B, exec, ${profile.browser}"
```

With:

```nix
"$mod, Return, exec, kitty"
"$mod SHIFT, Return, exec, kitty"
"$mod, B, exec, firefox"
```

Hardcode the defaults since they're always the same.

**Step 3: Test hyprland config evaluation**

```bash
nix eval .#nixosConfigurations.acer-swift.config.specialisation.desktop.configuration.home-manager.users.lukas.wayland.windowManager.hyprland.enable
```

Expected: `true`

**Step 4: Commit**

```bash
git add modules/desktop/hyprland/home.nix
git commit -m "refactor: hardcode terminal/browser in Hyprland keybindings"
```

---

## Phase 5: Update Documentation

### Task 5.1: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Update architecture section**

Replace sections about roles and desktop with specialisation pattern:

```markdown
### Desktop Specialisation

All hosts boot into **server mode** by default (optimized headless environment with full CLI tooling).

Hosts with compatible GPUs (Intel iGPU) have a **desktop specialisation** - an optional boot menu entry that adds:
- Hyprland Wayland compositor
- SDDM display manager
- Waybar, Rofi, theming
- GUI applications (Firefox, VS Code, Kitty)

**Boot menu:**
```
NixOS (default)  ← Server mode (always available)
NixOS (desktop)  ← GUI mode (Intel GPU hosts only)
```

**Hosts with desktop specialisation:**
- acer-swift
- lenovo-21CB001PMX

**Headless-only hosts:**
- msi-ms7758 (legacy NVIDIA Kepler GPU)
- workstation-template (VM image)
```

**Step 2: Update sam.profile section**

```markdown
### Profile System (`sam.profile`)

Essential host metadata in `config.sam.profile`:

**System:**
- `username`, `hostname`
- `timezone`, `locale`
- `kbdLayout`, `kbdVariant`, `consoleKeymap`

**Hardware:**
- `videoDriver` (intel, nvidia-kepler, nvidia-modern, amd)
- `monitors` (Hyprland monitor definitions)
- `laptop` (boolean)

**Infrastructure:**
- `roles` (list: base, laptop, homelab-agent, homelab-server)
- `lanCidr` (firewall trusted network)
- `sshAuthorizedKeys` (optional host-specific override)
```

**Step 3: Remove obsolete sections**

Delete references to:
- macOS/nix-darwin
- i3 desktop
- Desktop as a role
- LightDM
- profile.terminal, profile.browser, etc.

**Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for specialisation architecture"
```

---

### Task 5.2: Create Migration Document

**Files:**
- Create: `docs/2026-02-20-simplification-migration.md`

**Step 1: Document what changed**

Create migration doc explaining:
- Removed fields from sam.profile
- Desktop moved to specialisation
- How to boot into desktop mode (select in GRUB/systemd-boot menu)
- Dead code removed (macOS, i3, LightDM)

**Step 2: Commit**

```bash
git add docs/2026-02-20-simplification-migration.md
git commit -m "docs: add migration guide for simplification refactor"
```

---

## Phase 6: Final Testing & Verification

### Task 6.1: Test Build All Hosts

**Step 1: Build each host configuration**

```bash
nix build .#nixosConfigurations.acer-swift.config.system.build.toplevel --no-link
nix build .#nixosConfigurations.lenovo-21CB001PMX.config.system.build.toplevel --no-link
nix build .#nixosConfigurations.msi-ms7758.config.system.build.toplevel --no-link
nix build .#nixosConfigurations.workstation-template.config.system.build.toplevel --no-link
```

Expected: All builds succeed.

**Step 2: Verify specialisations**

```bash
nix eval .#nixosConfigurations.acer-swift.config.specialisation --apply builtins.attrNames
nix eval .#nixosConfigurations.lenovo-21CB001PMX.config.specialisation --apply builtins.attrNames
nix eval .#nixosConfigurations.msi-ms7758.config.specialisation --apply builtins.attrNames
```

Expected:
- acer-swift: `[ "desktop" ]`
- lenovo: `[ "desktop" ]`
- msi: `[ ]` (no specialisations)

**Step 3: Verify flake check**

```bash
nix flake check --all-systems --no-write-lock-file
```

Expected: Clean pass.

---

### Task 6.2: Count Lines Removed

**Step 1: Run diffstat**

```bash
git diff main --stat
```

**Step 2: Count sam.profile field reduction**

Before: 24 fields
After: 13 fields
Reduction: ~46%

**Step 3: Document cleanup metrics**

Expected reductions:
- Files deleted: 10+ (darwin, i3, lightdm, per-host home.nix)
- Lines removed: ~1000+
- Duplicate code eliminated: 5 copies of home.nix → 1 shared module

---

### Task 6.3: Deploy to Test Host

**Step 1: Build and deploy to acer-swift**

```bash
sudo nixos-rebuild switch --flake .#acer-swift
```

**Step 2: Verify base system boots**

Expected: Boots into server mode (no GUI, bash shell).

**Step 3: Test desktop specialisation**

```bash
sudo nixos-rebuild boot --flake .#acer-swift --specialisation desktop
sudo reboot
```

In bootloader menu, select "NixOS (desktop)" entry.

Expected: Boots into Hyprland with SDDM login.

**Step 4: Verify both modes work**

- Server mode: SSH works, k3s agent running, no GUI
- Desktop mode: Hyprland loads, Waybar visible, keybindings work

---

### Task 6.4: Final Commit & Branch Cleanup

**Step 1: Review all changes**

```bash
git log --oneline main..HEAD
```

**Step 2: Squash if needed**

```bash
# Optional: interactive rebase to clean up commit history
git rebase -i main
```

**Step 3: Final commit**

```bash
git add -A
git commit -m "refactor: simplify architecture (sam.profile, desktop specialisation, remove bloat)

BREAKING CHANGES:
- Removed sam.profile fields: desktop, terminal, browser, editor, displayManager, themes
- Desktop moved from role to NixOS specialisation (boot menu option)
- Deleted macOS/nix-darwin support (unused)
- Deleted i3 desktop environment (unused)
- Deleted LightDM display manager (unused)
- Consolidated 3 duplicate home.nix files into shared module

Benefits:
- 46% reduction in sam.profile complexity (24 → 13 fields)
- Boot-time desktop toggle (server mode default)
- ~1000 lines of code removed
- Eliminated code duplication (5 → 1 home.nix)
"
```

**Step 4: Tag the refactor**

```bash
git tag -a v2.0-simplification -m "Major simplification refactor"
```

---

## Success Criteria

- ✅ All 4 hosts build successfully
- ✅ acer-swift and lenovo have desktop specialisation in boot menu
- ✅ msi-ms7758 stays headless (no specialisation)
- ✅ sam.profile reduced from 24 to 13 fields
- ✅ No macOS, i3, or LightDM code remains
- ✅ Single shared home.nix (3 duplicates removed)
- ✅ Flake check passes
- ✅ Desktop specialisation boots and works on test host
- ✅ Server mode is default on all hosts
- ✅ Documentation updated

---

## Rollback Plan

If critical issues occur:

```bash
# Revert to main branch
git checkout main

# Or cherry-pick specific fixes
git cherry-pick <commit-hash>
```

Keep `modules/core/system.nix.backup` until verified working.
