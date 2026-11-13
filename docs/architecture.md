# Architecture

### Flake Entry Point

`flake.nix` is minimal. It hands every `.nix` file under `flake-modules/` (recursively, via the `import-tree` input) to flake-parts. The number prefixes are names only: module merging does not depend on them.

- `00-flake-parts-modules.nix` — flake-parts setup
- `05-overlays.nix` — exposes `pkgs/` through an overlay
- `10-systems.nix` — supported systems
- `20-module-registry.nix` — auto-generates module registries from filesystem
- `30-configurations-options.nix` — typed host declaration options
- `40-outputs-nixos.nix` — transforms declarations into `nixosConfigurations`
- `50-rf-hwsim-test.nix` — the rf-lab hwsim test package
- `60-templates.nix`: devShell flake templates (with `.envrc`) stamped by `dev-init`
- `64-rf-beacons-rs.nix`: the rf-proto beacon table package and its `rf-beacons-parity` check
- `70-deploy.nix`: deploy-rs push targets, one node per hosts table entry
- `hosts.nix`: the hosts table (roles, `hostDir`, `deploy.hostname`, `deploy.remoteBuild`)

### Module Registry (`20-module-registry.nix`)

Automatically generates `flake.modules` from filesystem conventions:
- `modules/roles/*.nix` → `flake.modules.nixos.role-<name>`
- `modules/home/*.nix` → `flake.modules.homeManager.<name>`

Home Manager is shared, not per-host: every host gets
`modules/home/default.nix`. There are no `hosts/*/home.nix` files.

### Host Configuration Flow

Each host has three files in `hosts/<name>/`:

| File | Purpose |
|------|---------|
| `variables.nix` | Plain attrset of host-specific choices (username, feature flags, etc.) |
| `configuration.nix` | NixOS system modules — imports `variables.nix`, sets `sam.profile` |
| `hardware-configuration.nix` | Auto-generated hardware scan |

The wiring: `flake-modules/hosts.nix` declares each host as a typed `configurations.nixos.<name>` entry (option in `30-configurations-options.nix`): its roles, `hostDir` where the directory differs from the name, `deploy.hostname` where it differs from the name, and the required `deploy.remoteBuild` (no default: a host without it fails evaluation). Then `40-outputs-nixos.nix` resolves roles to modules, sets `sam.profile.roles` from the entry, injects Stylix/SOPS/Home Manager/disko and `modules/workers`, and produces the final `nixosConfigurations.<name>`; `70-deploy.nix` maps every entry to `deploy.nodes.<name>`, with the fleet-wide ssh and rollback settings and `remoteBuild` only when true.

### Desktop vs Server Mode

Desktop mode is niri + SDDM + Waybar/Rofi/theming + GUI apps; headless mode
is simply its absence. **Each host has exactly one mode**, chosen by whether it
imports `modules/specialisations/desktop.nix` in its default boot:

| Host | Mode | Specialisations |
|------|------|-----------------|
| `lenovo-21CB001PMX` | **desktop** (daily-driver laptop, also the k3s control plane) | none |
| `acer-swift` | **headless** (k3s worker) | `desktop` (Niri GUI) |
| `msi-ms7758` | **headless** (intermittent opt-in k3s worker, dual-boot Windows) | none |
| `black-pi` | **headless** (aarch64 k3s worker, Raspberry Pi 4 on SD card, builds its own closure) | none |
| `naked-pi` | **headless** (aarch64 Wi-Fi learning node, Raspberry Pi 3, role `rf-lab`; not in k3s) | none |

`modules/specialisations/desktop.nix` imports `modules/desktop/common`
(compositor-agnostic bar, launcher, lock/idle, notifications, GTK) and
`modules/desktop/niri`, the only compositor.

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
desktop-only config on `programs.niri.enable` — that ties it to one
compositor. Stylix is the exception: it comes with `base`, so a headless host
is themed unless its role turns it off, which `runtime-host` (with an assertion) and `rf-lab` do.

### Profile System (`sam.profile`)

Defined in `modules/core/system.nix`. All host metadata lives in `config.sam.profile` — a typed NixOS option submodule. Modules read this instead of using `specialArgs`.

**Available fields** (the submodule is strict — anything not listed here is a
build error if a `variables.nix` sets it):
- `username` (one of the users in `lib/users.nix`): primary user account
- `hostname` (str) — System hostname
- `timezone` / `locale` / `kbdLayout` / `kbdVariant` / `consoleKeymap` (str): localisation; default to the fleet values (Europe/Stockholm, en_US.UTF-8, se, "", sv-latin1), set only to differ
- `roles` (list of str): enabled roles from `modules/roles/`, set from the host's entry in `flake-modules/hosts.nix`, not in `variables.nix`
- `devTools` (bool, default true): ship the interactive dev toolset (claude-code, codex, nvim toolchains, nodejs/chromium, herdr, pi-harness); false on appliance nodes
- `pi` (bool, default false): Pi coding agent module, provider-key exports and the `router/free` extension (docs/pi.md); the host also declares the sops secrets
- `nativeOtel` (bool, default false): native harness telemetry through the local relay (docs/native-otel-canary.md)
- `lanCidr` (str) — LAN subnet for firewall rules (default: "192.168.10.0/24")

Sibling options, outside the profile:
- `sam.desktop.enable` (bool) — whether a GUI desktop session is active (outside the profile so `modules/specialisations/desktop.nix` can set it)
- `sam.thermal.*` — fan/CPU thermal policy, see `modules/hardware/thermal.nix`
- `sam.hostSecrets.enable` (bool) — per-machine operator credentials, see `modules/core/sops.nix`
- `sam.wifi.*` — declarative WiFi profile, see `modules/core/wifi.nix`

Everything this repo defines lives under `sam.*` or `homelab.*` so it is never
confused with an upstream NixOS option. Which of the two is the Namespace
Boundary rule in Conventions.

### Roles (`modules/roles/`)

Composable role modules assigned per host in `flake-modules/hosts.nix`:
- **base**: required on every host (enforced by assertion); imports the `modules/core/` baseline (not `laptop`, `wifi`, `always-on`, `sddm`, `fish`)
- **laptop** — laptop-specific overrides
- **homelab-agent** — k3s worker node; disables sleep/suspend
- **homelab-server** — k3s control plane
- **runtime-host** — headless worker host, msi-ms7758 and acer-swift, running the declared nspawn developer environments
  (`sam.workers`, docs/nspawn-workers.md): the run credential, the deploy-rs target, no Stylix outside a
  desktop specialisation, and nix-gc / nix-optimise that wait for a synchronised clock
  (`systemd-time-wait-sync`), never catch up at boot and run one at a time
- **rf-lab** — headless Wi-Fi learning appliance (naked-pi)
- **embedded** — ESP32 development host (USB-serial, debug probes)

### Module Layout

```
modules/
├── core/         # System baseline (boot, users, network, services, packages, automation)
├── desktop/      # Desktop stack: common/ and niri/
├── embedded/     # ESP32 tooling
├── hardware/     # GPU drivers (intel), thermal, disk layouts
├── home/         # the shared Home Manager entry point
├── homelab/      # k3s (agent/server), sops, flux, tailscale, ntfy, watchdog
├── programs/     # Home Manager programs: cli/, browser/, editor/, gui/, terminal/
├── rf-lab/       # Wi-Fi/Bluetooth lab and HIL tests
├── roles/        # Composition roles (see above)
├── specialisations/  # Boot-menu variants (desktop.nix)
├── themes/       # Catppuccin via Stylix
└── workers/      # nspawn developer environments (docs/nspawn-workers.md)
```

