# Desktops (GUI)

> Desktop stacks and display managers used in this repo.

This repo treats “desktop” as just another role-driven aspect selected per host
via `sam.profile` (usually populated from `hosts/<host>/variables.nix`).

## Host Contract (`sam.profile`)

Common knobs:

- `desktop`: Desktop stack identifier.
  - Supported today: `hyprland`, `i3`
- `displayManager`: Login/greeter manager.
  - Supported today: `sddm`, `lightdm`
- `sddmTheme`: Only applies when `displayManager = "sddm"`.

Notes:

- `monitors` is currently a Hyprland-only concept (Wayland monitor rules).

Example host selection:

```nix
# hosts/acer-swift/variables.nix
{
  roles = [ "base" "laptop" "desktop" "homelab-agent" ];
  desktop = "hyprland";
  displayManager = "sddm"; # default (optional)
}
```

Headless hosts:

- Omit the `desktop` role entirely (no greeter, no GUI). The `desktop` and
  `displayManager` profile knobs become effectively irrelevant.

## Desktop Stacks

### `hyprland` (Wayland)

Files:

- System: `modules/desktop/hyprland/default.nix`
- Home Manager: `modules/desktop/hyprland/home.nix`

Characteristics:

- Wayland compositor + XWayland for X11 apps.
- Wayland-centric utilities (screenshots, clipboard, wallpaper) are expected.

### `i3` (X11)

Files:

- System: `modules/desktop/i3/default.nix`
- Home Manager: `modules/desktop/i3/home.nix`

Characteristics:

- Stable fallback for older GPUs and legacy driver stacks.
- Home Manager provides a minimal `~/.config/i3/config` with “Hyprland-like”
  keybind muscle memory (Mod+Enter, Mod+d/Space, Mod+h/j/k/l, etc).

## Display Managers

### `sddm`

File: `modules/core/sddm.nix`

- Default DM in this repo.
- Runs the greeter on Wayland only when the selected desktop is Wayland
  (`desktop = "hyprland"`). Otherwise it stays on X11.

### `lightdm`

File: `modules/core/lightdm.nix`

- X11-only greeter (GTK).
- Preferred for “deprecated” hardware where SDDM/Wayland can glitch.

## Legacy NVIDIA (Kepler / 470xx)

Kepler GPUs (GTX 600/700, e.g. GTX 680) are pinned to NVIDIA’s legacy 470xx
driver series. In practice, this combo is reliable on X11 but frequently
unreliable on modern Wayland compositors.

Repo stance:

- If the host is Kepler/470xx and you want “it just works”, use `desktop = "i3"`.
- Keep Wayland (Hyprland) for newer GPUs/drivers.

## Gaming Specialisation

See `docs/homelab-platform/tech/specialisations.md` for how this repo uses a
`specialisation.gaming` boot entry to disable k3s and enable Steam/GameMode.

## Applying Changes

```bash
sudo nixos-rebuild switch --flake .#<host>
reboot
```

## Adding Another Desktop Stack

1. Create `modules/desktop/<name>/default.nix` (system) and guard it with:
   `lib.mkIf (config.sam.profile.desktop == "<name>")`.
2. Create `modules/desktop/<name>/home.nix` (Home Manager) and import it from
   host HM entrypoints (already wired via `hosts/<host>/home.nix`).
3. Add `<name>` to the supported list in `modules/roles/desktop.nix`.
4. Document it here.
