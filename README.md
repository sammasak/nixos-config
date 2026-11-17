# NixOS Configuration

One flake that builds and deploys a six-host homelab: two laptops, two towers
and two Raspberry Pis, sharing one user and one Home Manager tree. Five of the
hosts run the homelab's services as NixOS units; the sixth is a Wi-Fi lab appliance. It is built with
flake-parts and pushed with deploy-rs from the daily-driver laptop.

## Hosts

| Host (flake attribute) | Hardware | Role |
|------------------------|----------|------|
| `lenovo-21CB001PMX` (`lenovo`) | Laptop | Daily driver with desktop; DNS, ntfy and Tailscale; deploys every other host |
| `acer-swift` | Laptop run headless | Always-on service host (Caddy edge, Authentik, chat, llm-gateway); `desktop` boot entry adds the Niri GUI |
| `msi-ms7758` | Tower, dual-boots Windows (GRUB) | Intermittent worker host, woken via Wake-on-LAN in its work-hours window |
| `asus-b460m` | Tower, dual-boots Windows (GRUB) | Worker host, offline while booted into Windows |
| `black-pi` | Raspberry Pi 4, aarch64 | Observability host (Prometheus, Grafana, Loki); builds its own closure on the Pi |
| `naked-pi` | Raspberry Pi 3, aarch64 | `rf-lab` Wi-Fi learning node and ESP32 host |

## Layout

```
flake.nix               inputs; hands every file in flake-modules/ to flake-parts
flake-modules/          the flake's outputs
  hosts.nix             the fleet: one entry per host, its roles and deploy fields
hosts/<name>/           per-machine facts: configuration.nix (sam.profile and host-only modules), hardware-configuration.nix
modules/roles/          base, laptop, homelab-agent, homelab-server, runtime-host, rf-lab, embedded
modules/core/           the system baseline; roles/base.nix imports most of it
modules/homelab/        host services: edge, AdGuard, ACME, sops, tailscale, ntfy, monitoring, watchdog
modules/home/, programs/  the one Home Manager tree every host gets
modules/desktop/, specialisations/  the niri GUI and the boot entry that enables it
modules/workers/        nspawn developer environments (docs/nspawn-workers.md)
modules/rf-lab/, embedded/  naked-pi appliance stacks: Wi-Fi lab, ESP32 USB access
modules/hardware/       Intel video, thermal policy, disk layout, the Pi SD image
modules/themes/         Catppuccin via Stylix
lib/, pkgs/             pure helpers; packages not in nixpkgs, exposed as an overlay
scripts/, tests/        QA gates, bench.sh, VM tests
secrets/                SOPS-encrypted material, scopes in .sops.yaml
docs/                   reference and working documents; dated records in docs/records/
metrics/                bench.sh history: eval time and counters, drvPaths, line counts
assets/, dotfiles/      wallpapers; the nvim config, symlinked from the checkout
```

## How a host is assembled

1. **One typed host table.** `flake-modules/hosts.nix` declares each host:
   its `roles`, and the deploy fields `hostname` and `remoteBuild`. The entry
   is a typed option (`flake-modules/hosts-option.nix`);
   `remoteBuild` has no default, so a new host must say where it is built.
2. **Roles are plain modules.** `flake-modules/module-registry.nix`
   registers every `modules/roles/<name>.nix` as the module `role-<name>`.
   A role imports what it needs; most import `base.nix` themselves.
3. **Hosts are built from the table.** `flake-modules/nixos-configurations.nix`
   builds `nixosConfigurations.<host>` from `hosts/<name>/configuration.nix`,
   the listed roles, and the modules every host gets (Stylix, sops-nix, Home
   Manager, disko, `modules/workers`). An unknown role, or a host without
   `base`, fails evaluation.
4. **Deploy nodes are derived.** `flake-modules/deploy.nix` maps every
   table entry to a deploy-rs node, so the host list is written once.

Per-host choices reach modules through `sam.profile`, a strict submodule each
host sets in its `configuration.nix`; an unknown field is an evaluation error,
and the host configurations pass nothing through `specialArgs`. Whether a host
has a GUI is decided by one option, `sam.desktop.enable`, which only
`modules/specialisations/desktop.nix` sets. Options this repo defines live
under `sam.*` or `homelab.*`, except `services.devEnvironments`
(`modules/workers`).

Refactors are checked with `just parity`: it compares every host's toplevel
drvPath and deploy-rs node at the merge base with the working tree, and fails
if anything moved. Details and rationale: [docs/architecture.md](docs/architecture.md)
and [docs/flake-wiring.md](docs/flake-wiring.md).

## Build, Switch, Deploy

Everything goes through the [Justfile](Justfile). `HOST` is the flake
attribute. `build`, `diff` and `switch` default it to the machine you are on;
`deploy`, `dry-activate` and `checks` require it.

```bash
just build  [HOST]      # build without activating
just diff   [HOST]      # build and show the package diff vs the running system
just switch [HOST]      # build and activate locally
just bump [input]       # update one flake input (default: skills); then just switch

# Push from lenovo with deploy-rs (magic rollback); the deploy-rs client runs under a 7G cap and
# skips deploy-rs's own flake check. The pre-push gate runs it on pushed non-docs
# commits; the recipe refuses a dirty tree or a HEAD not on origin/main (DEPLOY_UNGATED=1 breaks glass).
# HOST: lenovo (loopback), acer-swift, msi-ms7758 (Mon-Fri ~08:30-21:00), asus-b460m,
# black-pi (builds on the Pi, run inside zellij), naked-pi
just deploy HOST
just dry-activate HOST  # the units a deploy would restart, and the closure diff; activates nothing, fails if the dry activation does

just check              # full QA (lint, flake check with every host build, the tests)
just verify             # flake check: build every x86 host, evaluate the Pis
just parity [BASE]      # fail if any host's toplevel or deploy node moved since BASE
```

`just deploy` ends, whatever deploy-rs returned, by checking on the target that
`systemctl is-system-running` says `running`, no unit is in a restart loop (`auto-restart`, or
`activating` after a restart, which `running` hides) and `/run/current-system` is the system profile's
generation, and exits non-zero if any fails; it lists condition-skipped units without failing
(`scripts/post-deploy-check.sh`). That catches a deploy that left the host degraded, looping
or off that generation, for example a unit that fails after activation reported success. A failed check
rolls nothing back: the new generation stays. A host degraded for an unrelated, pre-existing
reason fails every deploy until fixed; read `systemctl --failed` on the target.

Rollback with `sudo nixos-rebuild switch --rollback`, or pick an older
generation in the boot menu.

## SSH Hardening

Policy lives in `modules/core/services.nix`, `network.nix` and `users.nix`:

- Key-only SSH auth (`PasswordAuthentication = false`)
- No root SSH login (`PermitRootLogin = "no"`)
- Allowed SSH users are explicit (`AllowUsers = [ username ]`, plus `deploy` on every host from
  `modules/homelab/deploy-target.nix`, whose key is accepted only from lenovo)
- SSH firewall policy allows only LAN CIDR + loopback; keys come from `lib/users.nix`

Apply an SSH policy change with `just deploy HOST`: magic rollback should revert a host the
`deploy` login can no longer reach, but that connectivity rollback is unexercised on every host (the
msi and black-pi rehearsals covered a failed activation, which the patched deploy-rs activate rolls
back), and it does not test `lukas`'s login, so keep a session open until a new one gets in. Not on naked-pi until it takes the patched activate (#474): apply it from a console there
first.

## Automation

No host upgrades itself: every host asserts `system.autoUpgrade` off, so it changes only through `just deploy HOST`. By default every host runs garbage collection monthly and optimises the store weekly; the Pis (weekly, 7-day retention, in `modules/hardware/pi-sd-image.nix`) and msi-ms7758 override the GC schedule. The defaults are in `modules/core/automation.nix`.

## Adding a New Host

`hosts/<name>/` plus an entry in `flake-modules/hosts.nix` (its deploy node
follows), the `just deploy` pattern, its known-hosts key and sops recipient
(list in CLAUDE.md). The full procedure is [docs/new-host.md](docs/new-host.md).

## Adding a New Service (Modular)

Use modules + roles, not ad-hoc host edits.

1. Create a reusable service module in `modules/<domain>/<service>.nix`.
2. Expose an option and guard config with `mkIf`:
   - Example: `options.homelab.<service>.enable = mkEnableOption "...";`
3. Add required ports/rules in the module itself (firewall stays close to service).
4. Attach module via a role (`modules/roles/*.nix`) if shared by multiple hosts.
5. Add that role to the host's `roles` in `flake-modules/hosts.nix` (or set the service option in `hosts/<name>/configuration.nix`).
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

## Further Reading

- [CLAUDE.md](CLAUDE.md): working rules, secrets scopes, Claude Code / Codex
  delivery, Comment Policy and conventions.
- [docs/pi.md](docs/pi.md): the Pi coding agent module (enabled on lenovo and
  acer-swift).
- [docs/herdr.md](docs/herdr.md): persistent Herdr sessions, agent restore,
  and reboot verification.
- [docs/new-host.md](docs/new-host.md): onboarding a new host, Windows dual boot included.
- [docs/factum-pilot.md](docs/factum-pilot.md): the Lenovo-only, advisory Factum CLI pilot.
- [docs/nix-audit-pilot.md](docs/nix-audit-pilot.md): the advisory nix-audit pilot on lenovo and the runtime hosts (acer-swift, msi-ms7758, asus-b460m).

References: [flake-parts](https://flake.parts/options/flake-parts-modules.html); inspired by
[Sly-Harvey/NixOS](https://github.com/Sly-Harvey/NixOS).
