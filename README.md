# NixOS Configuration

Personal NixOS + Home Manager flake for the homelab: laptops, a tower and two
Raspberry Pis, one shared user config, built with flake-parts.

- [CLAUDE.md](CLAUDE.md): working rules, secrets scopes, Claude Code / Codex
  delivery, Comment Policy and conventions.
- [docs/architecture.md](docs/architecture.md): flake composition, module
  registry, host wiring, `sam.profile` fields, desktop vs headless, roles.
- [docs/pi.md](docs/pi.md): the Pi coding agent module (enabled on lenovo and
  acer-swift).
- [docs/herdr.md](docs/herdr.md): persistent Herdr sessions, agent restore,
  and reboot verification.
- [docs/factum-pilot.md](docs/factum-pilot.md): the Lenovo-only, advisory Factum CLI pilot.
- [docs/nix-audit-pilot.md](docs/nix-audit-pilot.md): the advisory nix-audit pilot on lenovo, acer-swift and msi-ms7758.

## Hosts

| Host (flake attribute) | Hardware | Role |
|------------------------|----------|------|
| `lenovo-21CB001PMX` (`lenovo`) | Laptop | Daily driver with desktop; k3s control plane; deploys every other host |
| `acer-swift` | Laptop run headless | k3s worker (the only general one); `desktop` boot entry adds the Niri GUI |
| `msi-ms7758` | Tower, dual-boots Windows (GRUB) | Intermittent k3s agent, woken via Wake-on-LAN, tainted so only tolerating pods land |
| `black-pi` | Raspberry Pi 4, aarch64 | k3s agent; builds its own closure on the Pi |
| `naked-pi` | Raspberry Pi 3, aarch64 | `rf-lab` Wi-Fi learning node and ESP32 host; not in k3s |

## Structure

Every directory has one job. Where two places could hold a thing, this table is
the tie-breaker.

| Path | Owns | Notes |
|------|------|-------|
| `flake.nix` | Flake entry point | Recursively auto-imports `flake-modules/`; nothing host-specific |
| `flake-modules/` | Top-level flake composition | Number prefixes are names only, not an order; `hosts/<name>.nix` declares each host |
| `hosts/<name>/` | Per-machine facts only | `variables.nix` (choices), `configuration.nix` (host-only modules), `hardware-configuration.nix` (generated) |
| `modules/core/` | System modules | `roles/base.nix` imports the baseline every host gets; `laptop`, `wifi`, `always-on`, `sddm` come in through roles, hosts or the desktop specialisation |
| `modules/roles/` | Composition | `base`, `laptop`, `homelab-agent`, `homelab-server`, `runtime-host`, `rf-lab`, `embedded`; selected in `variables.nix` |
| `modules/homelab/` | Cluster concerns | k3s, flux, tailscale, ntfy, AdGuard, ACME, watchdogs, rebuild trigger |
| `modules/desktop/` | The GUI stack | niri, Waybar, Rofi; gated on `sam.desktop.enable` |
| `modules/specialisations/` | Boot-menu variants | Currently only `desktop.nix` |
| `modules/hardware/` | GPU, thermal, disk layout | the host imports `video/<videoDriver>.nix`, with `videoDriver` from its `variables.nix` |
| `modules/rf-lab/`, `modules/embedded/` | naked-pi appliance stacks | Wi-Fi/Bluetooth lab and HIL tests; ESP32 tooling |
| `modules/home/` | Shared Home Manager entry point | One tree for all hosts; there are no per-host `home.nix` files |
| `modules/programs/` | Home Manager program modules | `cli/`, `browser/`, `editor/`, `gui/`, `terminal/` |
| `modules/workers/` | nspawn developer environments | `sam.workers`, see docs/nspawn-workers.md |
| `modules/themes/` | Catppuccin via Stylix | |
| `lib/` | Pure helpers, no module semantics | `users.nix` (git identity, SSH keys), `firewall.nix` (dual-backend rule builder) |
| `scripts/` | Repo tooling | `gate-probe.nix` and the `test-*.py` gates, `bench.sh`, `nix-comment-metrics.awk` |
| `metrics/` | Benchmark history | `history.jsonl`, one line per `just bench`; tracked, diffed across sessions |
| `secrets/` | SOPS-encrypted material | `.sops.yaml` holds the recipient scopes |
| `docs/` | Reference, plus dated records | Reference: `architecture.md`, `herdr.md`, `pi.md`, `nspawn-workers.md`, `ssh-host-keys.md`, `native-otel-canary.md`, `factum-pilot.md`, `nix-audit-pilot.md`. The rest are dated plans, measurements and ledgers, true as of their date |
| `Justfile` | Task entry points | build, switch, deploy, verify and image recipes |
| `assets/`, `dotfiles/` | Wallpapers; plain config files symlinked verbatim | |
| `pkgs/` | Packages not in nixpkgs | Exposed through an overlay in `flake-modules/` |

## Build, Switch, Deploy

Everything goes through the [Justfile](Justfile). `HOST` is the flake
attribute and defaults to the machine you are on.

```bash
just build  [HOST]      # build without activating
just diff   [HOST]      # build and show the package diff vs the running system
just switch [HOST]      # build and activate locally
just bump [input]       # update one flake input (default: skills); then just switch

# Push from lenovo with deploy-rs (magic rollback)
just deploy-acer
just deploy-msi         # only in its Mon-Fri ~09:00-21:00 power window
just deploy-pi          # black-pi; builds on the Pi, run inside zellij
just deploy-naked-pi
just deploy-lenovo      # loopback self-push

just check              # full QA (lint, flake check with every host build, the tests)
just verify             # flake check: build every x86 host, evaluate the Pis
```

Rollback with `sudo nixos-rebuild switch --rollback`, or pick an older
generation in the boot menu.

Every host has a deploy-rs node. The plain SSH fallback is in CLAUDE.md; if
it fails with `sudo: a terminal is required to read the password`, add
`--ask-sudo-password`; target by IP when hostnames are flaky.

## SSH Hardening

Policy lives in `modules/core/services.nix`, `network.nix` and `users.nix`:

- Key-only SSH auth (`PasswordAuthentication = false`)
- No root SSH login (`PermitRootLogin = "no"`)
- Allowed SSH users are explicit (`AllowUsers = [ username ]`, plus `deploy` on every host from
  `modules/homelab/deploy-target.nix`, whose key is accepted only from lenovo)
- SSH firewall policy allows only LAN CIDR + loopback; keys come from `lib/users.nix`

After changing SSH policy, apply locally on the target first
(`just switch` there) to avoid locking yourself out.

## Automation

`modules/core/automation.nix` turns on a weekly auto-upgrade from `github:sammasak/nixos-config/main` (Sunday 06:00, plus up to 45 min of jitter), monthly garbage collection and weekly store optimisation. Only `acer-swift` keeps the auto-upgrade, with `allowReboot = false` (it is the sole worker); lenovo, msi-ms7758, black-pi and naked-pi force it off. naked-pi collects garbage weekly.

## Adding a New Host

`hosts/<name>/` plus `flake-modules/hosts/<name>.nix`; full procedure
(including SOPS recipients) in `~/knowledge/homelab/runbooks/add-new-host.md`.

## Adding a New Service (Modular)

Use modules + roles, not ad-hoc host edits.

1. Create a reusable service module in `modules/<domain>/<service>.nix`.
2. Expose an option and guard config with `mkIf`:
   - Example: `options.homelab.<service>.enable = mkEnableOption "...";`
3. Add required ports/rules in the module itself (firewall stays close to service).
4. Attach module via a role (`modules/roles/*.nix`) if shared by multiple hosts.
5. Enable that role (or service option) in `hosts/<name>/configuration.nix`.
6. Build/apply locally, then remote deploy if needed.

Template:

```nix
{ config, lib, ... }:
let
  inherit (lib) mkEnableOption mkIf;
  cfg = config.homelab.myservice;
in
{
  options.homelab.myservice.enable = mkEnableOption "My service";

  config = mkIf cfg.enable {
    # service config
  };
}
```

## Customization

| What | Where |
|------|-------|
| Theme & colors | [modules/themes/Catppuccin/default.nix](modules/themes/Catppuccin/default.nix) |
| Wallpaper | `assets/wallpapers/` |
| Git credentials | [lib/users.nix](lib/users.nix) |
| niri keybinds | [modules/desktop/niri/home.nix](modules/desktop/niri/home.nix) |
| Desktop stacks | `modules/specialisations/desktop.nix` and `modules/desktop/` |

References: [flake-parts](https://flake.parts/options/flake-parts-modules.html); inspired by
[Sly-Harvey/NixOS](https://github.com/Sly-Harvey/NixOS).
