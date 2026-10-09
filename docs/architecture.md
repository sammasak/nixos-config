# Architecture (moved from CLAUDE.md 2026-10-09)

### Flake Entry Point

`flake.nix` is minimal. It recursively auto-imports all `.nix` files from `flake-modules/` using `collectFlakeModules`. The `flake-modules/` directory is numbered for load order:

- `00-flake-parts-modules.nix` — flake-parts setup
- `10-systems.nix` — supported systems
- `20-module-registry.nix` — auto-generates module registries from filesystem
- `30-configurations-options.nix` — typed host declaration options
- `40-outputs-nixos.nix` — transforms declarations into `nixosConfigurations`
- `hosts/<name>.nix` — per-host distribution declarations

### Module Registry (`20-module-registry.nix`)

Automatically generates `flake.modules` from filesystem conventions:
- `modules/roles/*.nix` → `flake.modules.nixos.role-<name>`
- `modules/home/*.nix` → `flake.modules.homeManager.<name>`

Home Manager is shared, not per-host: every host gets
`modules/home/default.nix`. There are no `hosts/*/home.nix` files.

### Host Configuration Flow

Each host follows a 2–3 file pattern in `hosts/<name>/`:

| File | Purpose |
|------|---------|
| `variables.nix` | Plain attrset of host-specific choices (username, roles, videoDriver, monitors, etc.) |
| `configuration.nix` | NixOS system modules — imports `variables.nix`, sets `sam.profile` |
| `hardware-configuration.nix` | Auto-generated hardware scan |

The wiring: `flake-modules/hosts/<name>.nix` reads `variables.nix` and creates a typed `configurations.nixos.<name>` declaration. Then `40-outputs-nixos.nix` resolves roles to modules, injects Stylix/SOPS/Home Manager, and produces the final `nixosConfigurations.<name>`.

### Desktop vs Server Mode

Desktop mode is Hyprland + SDDM + Waybar/Rofi/theming + GUI apps; headless mode
is simply its absence. **Each host has exactly one mode**, chosen by whether it
imports `modules/specialisations/desktop.nix` in its default boot:

| Host | Mode | Specialisations |
|------|------|-----------------|
| `lenovo-21CB001PMX` | **desktop** (daily-driver laptop, also the k3s control plane) | none |
| `acer-swift` | **headless** (k3s worker) | `desktop` (Niri GUI) |
| `msi-ms7758` | **headless** (intermittent opt-in k3s worker, dual-boot Windows) | none |

Desktop mode ships **two coexisting compositors** — Hyprland and niri, both
imported by `modules/specialisations/desktop.nix`; the compositor is picked
at the SDDM greeter and niri is the default/daily driver.

The Acer headless configuration is the default and its `desktop` specialisation
adds the Niri GUI boot entry. MSI is an intermittent opt-in k3s worker: powered
on only occasionally (woken via Wake-on-LAN), tainted
`sammasak.dev/intermittent=true:NoSchedule` so nothing schedules on it unless it
tolerates that. Its root/shared-Windows-ESP UUIDs are verified; boot stays GRUB
with a manual Windows Boot Manager entry (dual-boot preserved).

**One signal decides GUI-ness:** `sam.desktop.enable`. It is set by
`modules/specialisations/desktop.nix`; the default is `false`, so a host that
does not import that module is headless. Fonts, GUI packages, desktop services
and the Home Manager desktop imports all key off it. Do not gate new
desktop-only config on `programs.hyprland.enable` — that ties it to one
compositor.

### Profile System (`sam.profile`)

Defined in `modules/core/system.nix`. All host metadata lives in `config.sam.profile` — a typed NixOS option submodule. Modules read this instead of using `specialArgs`.

**Available fields** (the submodule is strict — anything not listed here is a
build error if a `variables.nix` sets it):
- `username` (str) — Primary user account
- `hostname` (str) — System hostname
- `timezone` / `locale` / `kbdLayout` / `kbdVariant` / `consoleKeymap` (str) — Localisation
- `videoDriver` (str) — GPU driver module selector; picks `modules/hardware/video/<value>.nix` (currently only "intel")
- `monitors` (list of str) — Hyprland monitor rules, `name,resolution,position,scale`
- `roles` (list of str) — Enabled roles from `modules/roles/`
- `laptop` (bool) — Laptop-specific settings enabled
- `lanCidr` (str) — LAN subnet for firewall rules (default: "192.168.10.0/24")
- `sshAuthorizedKeys` (list of str) — Authorized SSH public keys

Sibling options, outside the profile:
- `sam.desktop.enable` (bool) — whether a GUI desktop session is active (outside the profile so `modules/specialisations/desktop.nix` can set it)
- `sam.thermal.*` — fan/CPU thermal policy, see `modules/hardware/thermal.nix`
- `sam.hostSecrets.enable` (bool) — per-machine operator credentials, see `modules/core/sops.nix`
- `sam.wifi.*` — declarative WiFi profile, see `modules/core/wifi.nix`

Everything this repo defines lives under `sam.*` or `homelab.*` so it is never
confused with an upstream NixOS option. Which of the two is the Namespace
Boundary rule in Conventions.

### Roles (`modules/roles/`)

Composable role modules assigned per-host via `variables.nix`:
- **base** — required on every host (enforced by assertion); imports all `modules/core/`
- **laptop** — laptop-specific overrides
- **homelab-agent** — k3s worker node; disables sleep/suspend
- **homelab-server** — k3s control plane

### Module Layout

```
modules/
├── core/         # System baseline (boot, users, network, services, packages, automation)
├── desktop/      # Desktop stack: hyprland/ and niri/ (Wayland compositors)
├── hardware/     # GPU drivers (intel), thermal
├── homelab/      # k3s (agent/server), sops, flux, tailscale, ntfy, watchdog
├── programs/     # Home Manager programs: cli/, browser/, editor/, terminal/
├── roles/        # Composition roles (see above)
└── themes/       # Catppuccin via Stylix
```

