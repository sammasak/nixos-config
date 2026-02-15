# NixOS Specialisations

Specialisations let one NixOS host produce multiple bootable system variants
from the same base configuration (extra boot menu entries).

This repo uses specialisations primarily for a "worker by default" desktop that
can temporarily boot into a gaming-focused system where k3s is disabled.

## Pattern In This Repo

Implementation: `modules/core/gaming-specialisation.nix`

- Default boot: worker mode.
  - `homelab.k3s.enable = true` via the `homelab-agent` role.
- Optional: gaming boot entry.
  - When `sam.profile.games = true`, the module adds:
    - `specialisation.gaming.configuration`
    - which disables k3s (`services.k3s` and the repo wrapper `homelab.k3s`)
    - and enables gaming stack (Steam, GameMode, Gamescope).
- Optional: hardware control baseline (fan/RGB/thermals).
  - `sam.profile.hardwareControl = true` enables baseline hardware control in
    the default (worker) system without requiring a gaming specialisation.

## Example (Next Gaming Desktop)

```nix
# hosts/<new-host>/variables.nix
{
  # Desktop
  desktop = "hyprland";

  # Features
  games = true;            # adds boot entry: specialisation "gaming"
  hardwareControl = true;  # enables fan/RGB/thermals in worker mode too

  # Roles
  roles = [ "base" "desktop" "homelab-agent" ];
}
```

Expected behavior:

- Booting the default entry keeps the node in the cluster as a worker.
- Booting the "gaming" specialisation drops out of the cluster and enables the
  gaming stack.

## Fan Control Files (Optional)

If you want `fancontrol`, generate a config on the host:

```bash
sudo pwmconfig
```

Then commit the resulting `/etc/fancontrol` as one of:

- `hosts/<hostname>/fancontrol-worker.conf` (default/worker curve)
- `hosts/<hostname>/fancontrol-gaming.conf` (optional alternate curve)

If only `hosts/<hostname>/fancontrol-worker.conf` exists, it is used for both
worker and gaming specialisation.

## Verifying At Runtime

After booting:

```bash
# should exist when games=true
ls -la /run/current-system/specialisation

# default boot should be active; gaming boot should be inactive
systemctl status k3s
```

