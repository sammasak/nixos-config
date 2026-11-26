# Architecture

### Flake Entry Point

`flake.nix` is minimal. It hands every `.nix` file under `flake-modules/` (recursively, via the `import-tree` input) to flake-parts.

- `flake-parts-modules.nix` — flake-parts setup
- `overlays.nix` — exposes `pkgs/` through an overlay and defines the `nix fmt` formatter
- `systems.nix` — supported systems
- `module-registry.nix` — auto-generates module registries from filesystem
- `hosts-option.nix` — typed host declaration options
- `nixos-configurations.nix` — transforms declarations into `nixosConfigurations`
- `rf-hwsim-test.nix` — the rf-lab hwsim test package
- `runtime-host-vm-test.nix`: the QEMU tests (x86_64-linux only), `runtime-host-role-vm` (the base and runtime-host roles with msi-ms7758's role list), `dev-env-reset-vm`, `socket-rebind-vm`, `rebuild-trigger-vm` and `post-deploy-check-vm` (`just deploy`'s unit check against real systemd states), as flake checks only (the gate boots them; `just role-vm-test` builds the check and its `.broken`): as packages too, the flake check evaluated each twice
- `templates.nix`: devShell flake templates (with `.envrc`) stamped by `dev-init`
- `rf-beacons-rs.nix`: the rf-proto beacon table package and its `rf-beacons-parity` check
- `loki-check.nix`: the `loki-config-msi-ms7758` check (x86_64-linux), homelab.loki on a seeded msi: `loki -verify-config` on the rendered file and the module's assertions, held and failing; `loki-ruler-black-pi`, black-pi's ruler config verified and run on loopback (`scripts/test-loki-ruler.py`)
- `authentik-backup-check.nix`: Authentik's off-host copy spans acer (dump, `latest`) and lenovo (pull); neither host's evaluation sees both halves
- `grafana-dashboards-check.nix`: black-pi's dashboards against the metrics the fleet exports, with seeded failing dashboards
- `journal-collector-check.nix`: `alloy validate` on the config black-pi's journal collector renders (an aarch64 host is only evaluated)
- `llm-bench.nix`: the local-inference benchmark package and its `gpu-telemetry-exporter` and `llm-bench-scorecard` checks
- `monitoring-check.nix`: black-pi's promtool, amtool and blackbox config checks seeded onto an x86 host, plus the per-host rule test
- `app-manifest-check.nix`: the `app-manifest` check, app manifest admission and its edge-site and scrape rendering (`lib/app-manifest`, no host imports it) over its fixtures against the fleet's facts, the rendering compared with golden files and checked by caddy and promtool; see `docs/app-manifest.md`
- `shipping-check.nix`: the shipping rules and dashboard against the metric names emitted or recorded, and promtool alert tests
- `deploy.nix`: deploy-rs push targets, one node per hosts table entry
- `hosts.nix`: the hosts table (roles, `hostDir`, `deploy.hostname`, `deploy.remoteBuild`)

### Module Registry (`module-registry.nix`)

Automatically generates `flake.modules` from filesystem conventions:
- `modules/roles/*.nix` → `flake.modules.nixos.role-<name>`
- `modules/home/*.nix` → `flake.modules.homeManager.<name>`

Home Manager is shared, not per-host: every host gets
`modules/home/default.nix`. There are no `hosts/*/home.nix` files.

### Host Configuration Flow

Each host has three files in `hosts/<name>/`:

| File | Purpose |
|------|---------|
| `configuration.nix` | NixOS system modules; sets `sam.profile` (username, hostname, feature flags) |
| `hardware-configuration.nix` | Auto-generated hardware scan |
| `ssh_known_hosts` | Its verified SSH host key, pinned on every host (`docs/ssh-host-keys.md`) |

The wiring: `flake-modules/hosts.nix` declares each host as a typed `configurations.nixos.<name>` entry (option in `hosts-option.nix`): its roles, `hostDir` where the directory differs from the name, `deploy.hostname` where it differs from the name, and the required `deploy.remoteBuild` (no default: a host without it fails evaluation). Then `nixos-configurations.nix` resolves roles to modules, sets `sam.profile.roles` from the entry, injects Stylix/SOPS/Home Manager/disko and `modules/workers`, and produces the final `nixosConfigurations.<name>`; `deploy.nix` maps every entry to `deploy.nodes.<name>`, with the fleet-wide ssh and rollback settings and `remoteBuild` only when true.

### Desktop vs Server Mode

Desktop mode is niri + SDDM + Waybar/Rofi/theming + GUI apps; headless mode
is simply its absence. **Each host has exactly one mode**, chosen by whether it
imports `modules/specialisations/desktop.nix` in its default boot:

| Host | Mode | Specialisations |
|------|------|-----------------|
| `lenovo-21CB001PMX` | **desktop** (daily-driver laptop, also the DNS, ntfy and deploy host) | none |
| `acer-swift` | **headless** (the always-on service host: Caddy edge, Authentik, chat, llm-gateway) | `desktop` (Niri GUI) |
| `msi-ms7758` | **headless** (intermittent worker host, dual-boot Windows) | `gaming` (Niri GUI, Steam; no inference, no Sunshine or inbound ports, no evening power-off) |
| `asus-b460m` | **headless** (worker host, dual-boot Windows) | `gaming` (Niri GUI, Steam, Sunshine; no inference, no evening power-off) |
| `black-pi` | **headless** (aarch64 observability host, Raspberry Pi 4 on SD card, builds its own closure) | none |
| `naked-pi` | **headless** (aarch64 Wi-Fi learning node, Raspberry Pi 3, role `rf-lab`) | none |

`modules/specialisations/desktop.nix` imports `modules/desktop/common`
(compositor-agnostic bar, launcher, lock/idle, notifications, GTK) and
`modules/desktop/niri`, the only compositor, and `modules/desktop/sddm`.

The Acer headless configuration is the default and its `desktop` specialisation
adds the Niri GUI boot entry. MSI is an intermittent worker host: powered
on only in its work-hours window (woken via Wake-on-LAN). Its root/shared-Windows-ESP UUIDs are verified; boot stays GRUB
with a manual Windows Boot Manager entry (dual-boot preserved).

The `gaming` specialisation (`modules/specialisations/gaming.nix`) is the desktop entry plus Steam and GameMode
with 32-bit graphics, on both towers. Steam opens no inbound port (its Remote Play and dedicated-server firewall
options stay off), but once signed in its Remote Play can still stream through Valve's relay, outbound only; to keep a
host from streaming, turn Remote Play off in the Steam client (Settings, Remote Play), as no NixOS option does it.
The scheduled power-off timer is masked and the workers' shutdown notice does not run in the entry, so a game
outlasts the 21:00 power-off (Mon-Fri on msi, every day on asus): power the host off by hand afterwards. Wake-on-LAN
stays armed and the morning wake still applies. A `just deploy` to the host during a gaming session switches it live
back to the default configuration, which re-arms the 21:00 power-off and starts Ollama.

On ASUS the entry adds Sunshine, for Moonlight clients on the LAN, with two apps, Desktop and Steam Big Picture: the
session logs in by itself, Ollama, its model loader and the GPU power limit are not started, and Sunshine's stream ports are admitted from the LAN (`sam.fleet.public`). The host has no keyboard, so
enter it from the running system with `sudo grub-reboot --boot-directory=/boot-nix "NixOS - gaming" && sudo reboot`
(a one-time choice: the next plain boot is the headless inference host again). Only a reboot frees the card: a live
switch into the entry leaves Ollama running. The worker pool keeps running in the entry and shares the CPU with a game. Sunshine's web
UI, which sets its password and pairs a client by PIN, is not opened: reach it with
`ssh -L 47990:localhost:47990 asus-b460m` and `https://localhost:47990`.

MSI has the same `gaming` entry without streaming (`sam.gaming.streaming = false`): the Niri session behind the
SDDM greeter, played at the machine, with Ollama and its model loader not started and no idle lock. Enter it at the
keyboard by picking "NixOS - gaming" in the GRUB menu at boot. No Sunshine unit or wrapper
exists there (Steam's hardware support does load uinput and add its udev rules), no port is opened for it, and `sam.fleet.public` lists none for msi: the entry's assertion
fails evaluation if a host with streaming off has lan public entries, or one with streaming on lacks Sunshine's.
The nspawn workers run in this entry as in the default boot.

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
build error if a host sets it):
- `username` (one of the users in `lib/users.nix`): primary user account
- `hostname` (str) — System hostname
- `roles` (list of str): enabled roles from `modules/roles/`, set from the host's entry in `flake-modules/hosts.nix`, not in the host's `configuration.nix`
- `devTools` (bool, default true): ship the interactive dev toolset (claude-code, codex, nvim toolchains, nodejs/chromium, herdr, pi-harness); false on appliance nodes
- `pi` (bool, default false): Pi coding agent module, provider-key exports and the `router/free` extension (docs/pi.md); the host also declares the sops secrets
- `nativeOtel` (bool, default false): native harness telemetry through the local relay (docs/native-otel-canary.md)

Sibling options, outside the profile:
- `sam.desktop.enable` (bool) — whether a GUI desktop session is active (outside the profile so `modules/specialisations/desktop.nix` can set it)
- `sam.thermal.*` — fan/CPU thermal policy, see `modules/hardware/thermal.nix`
- `sam.hostSecrets.enable` (bool) — per-machine operator credentials, see `modules/core/sops.nix`
- `sam.cliTools.factum.enable`, `sam.cliTools.nixAudit.enable` (bool, default false): CLI tools in the user's Home Manager profile (factum on lenovo; nixAudit on lenovo and by the runtime-host role); outside the profile because a developer environment's guest copies its host's profile
- `sam.fleet` (read-only, set in `modules/core/fleet.nix`): LAN facts more than one module reads, `hosts.<hostName>.address` and `gateway` (IPv4), per host `extraAddresses` (other NIC addresses, for source-scoped rules), `sleeps` (may be off: store caches skip it, alerts expect it), `power` (work-hours window: `mac`, `interface`, `wake`, `off`; `modules/core/power-schedule.nix`) and `gpu` (`"nvidia"`, for its telemetry); fleet-wide `edge`, the hostName that serves `*.sammasak.dev`, `lanCidr`, the trusted LAN subnet of the firewall rules, `deployer`, the hostName whose key `deploy-target.nix` accepts and that refuses developer environments, and `ntfy`/`loki` (`host`, `port`, and the derived `url`) with `pageUrl`, the ntfy topic every failed service pages and the default of each module's page URL; a host that sets it fails evaluation

Everything this repo defines lives under `sam.*` or `homelab.*` so it is never
confused with an upstream NixOS option. Which of the two is the Namespace
Boundary rule in Conventions.

### Roles (`modules/roles/`)

Composable role modules assigned per host in `flake-modules/hosts.nix`:
- **base**: required on every host (enforced by assertion); imports the `modules/core/` baseline (not `laptop`, `wifi`, `always-on`), the deploy-rs target and the native-otel relay
- **laptop** — laptop-specific overrides
- **homelab-agent** — always-on fleet host that is not the control host; disables sleep/suspend, ModemManager and Nix trust for the login user
- **homelab-server** — the control host (lenovo); turns on dns (with TLS), acme, ntfy and the rebuild trigger, and
  imports AdGuard Home, tailscale and the alerting watchdog
- **runtime-host** — headless worker host, msi-ms7758, asus-b460m and acer-swift, running the declared nspawn developer environments
  (`sam.workers`, docs/nspawn-workers.md): the run credential, no Stylix outside a
  desktop specialisation, and nix-gc / nix-optimise that wait for a synchronised clock
  (`systemd-time-wait-sync`), never catch up at boot and run one at a time
- **rf-lab** — headless Wi-Fi learning appliance (naked-pi)
- **embedded** — ESP32 development host (USB-serial, debug probes)

### Module Layout

```
modules/
├── core/         # System baseline (boot, users, network, services, packages, automation)
├── desktop/      # Desktop stack: common/, niri/ and sddm/
├── embedded/     # ESP32 tooling
├── hardware/     # GPU drivers (intel), thermal, disk layouts
├── home/         # the shared Home Manager entry point
├── homelab/      # host services: edge, AdGuard, sops, tailscale, ntfy, monitoring, watchdog
├── programs/     # Home Manager programs: cli/, browser/, editor/, gui/, terminal/
├── rf-lab/       # Wi-Fi/Bluetooth lab and HIL tests
├── roles/        # Composition roles (see above)
├── specialisations/  # Boot-menu variants (desktop.nix)
├── themes/       # Catppuccin via Stylix
└── workers/      # nspawn developer environments (docs/nspawn-workers.md)
```

Module class follows the directory for these: `modules/core` and `modules/homelab` are NixOS, `modules/home` and `modules/programs` are Home Manager, and in `modules/desktop` each `<x>/default.nix` (NixOS) pairs with `<x>/home.nix` (Home Manager) where there is one. Exceptions: `core/users.nix` also holds the inline `home-manager.users` block; the files `desktop/common/home.nix` imports (`programs/*/`, `scripts/`) are Home Manager despite their `default.nix` names.

