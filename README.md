# NixOS Configuration

Personal NixOS + Home Manager configuration. A work in progress as I learn the Nix ecosystem.

## Goals

- Unified config across Linux desktops and servers
- Single user config that adapts to each machine type
- Reproducible, declarative system management
- Learn Nix patterns and best practices along the way

## Current Machines

| Machine | Type | Boot entries |
|---------|------|--------------|
| `acer-swift` | Laptop run headless as the sole k3s worker | Headless only |
| `lenovo-21CB001PMX` | Daily-driver laptop and k3s control plane | Hyprland desktop (default), `niri` |

The cross-mode specialisations (`lenovo`'s `server` entry, `acer-swift`'s
`desktop` entry) were removed on 2026-08-27 — neither had ever been booted, and
each cost a second full system closure on every rebuild.

## Structure

Every directory has one job. Where two places could hold a thing, this table is
the tie-breaker.

| Path | Owns | Notes |
|------|------|-------|
| `flake.nix` | Flake entry point | Recursively auto-imports `flake-modules/`; nothing host-specific |
| `flake-modules/` | Top-level flake composition | Numbered for load order; see table below |
| `flake-modules/hosts/` | One typed distribution declaration per host | Reads `hosts/<name>/variables.nix` |
| `hosts/<name>/` | Per-machine facts only | `variables.nix` (choices), `configuration.nix` (host-only modules), `hardware-configuration.nix` (generated) |
| `modules/core/` | System baseline on every host | boot, users, network, services, packages, automation, sops, wifi, resource-hygiene |
| `modules/roles/` | Composition | `base`, `laptop`, `homelab-agent`, `homelab-server`; selected in `variables.nix` |
| `modules/homelab/` | Cluster concerns | k3s, flux, tailscale, ntfy, AdGuard, ACME, watchdogs, rebuild trigger |
| `modules/desktop/` | The GUI stack | Hyprland, Waybar, Rofi; gated on `sam.desktop.enable` |
| `modules/specialisations/` | Boot-menu variants | Currently only `desktop.nix` |
| `modules/hardware/` | GPU and thermal | `video/<driver>.nix` picked by `sam.profile.videoDriver` |
| `modules/home/` | Shared Home Manager entry point | One tree for all hosts — there are no per-host `home.nix` files |
| `modules/programs/` | Home Manager program modules | `cli/`, `browser/`, `editor/`, `terminal/` |
| `modules/themes/` | Catppuccin via Stylix | |
| `lib/` | Pure helpers, no module semantics | `users.nix` (git identity, SSH keys), `firewall.nix` (dual-backend rule builder) |
| `scripts/` | Repo tooling | `verify-all-hosts.sh`, `bench.sh` |
| `metrics/` | Benchmark history | `history.jsonl`, one line per `just bench`; tracked, diffed across sessions |
| `secrets/` | SOPS-encrypted material | `.sops.yaml` holds the recipient scopes |
| `docs/` | Superseded design docs | Banner-marked; kept for history, not current |
| `Justfile` | Task entry points | `verify`, `check`, `bench`, `bench-diff`, `parity` |
| `assets/`, `dotfiles/` | Wallpapers; plain config files symlinked verbatim | |
| `pkgs/` | Packages not in nixpkgs | Exposed through an overlay in `flake-modules/` |

`flake-modules/` in load order:

| File | Job |
|------|-----|
| `00-flake-parts-modules.nix` | flake-parts setup |
| `10-systems.nix` | Supported systems |
| `20-module-registry.nix` | Auto-generates `flake.modules` from the filesystem |
| `30-configurations-options.nix` | Typed host declaration options |
| `40-outputs-nixos.nix` | Turns declarations into `nixosConfigurations` |

## How It Works

Each host lives in `hosts/<name>/` and provides:

- `variables.nix`: choices for desktop, theme, apps, hardware
- `configuration.nix`: system modules for that host

Home Manager is shared rather than per-host: every machine gets
`modules/home/default.nix`, which imports the CLI baseline and adds the GUI
program set when `sam.desktop.enable` is true.

[flake.nix](flake.nix) now uses **flake-parts** with `flake-parts.flakeModules.modules` (the `deferredModule` registry):

- Every file under `flake-modules/` is imported as a top-level flake module
- `flake.modules.nixos.role-*` is auto-generated from `modules/roles/*.nix`
- `flake.modules.homeManager.*` is auto-generated from `modules/home/*.nix`
- `configurations.nixos.*` are typed distribution declarations converted into flake outputs

This establishes a dendritic-style flake trunk for top-level composition: typed, classed module registries with no lower-level `specialArgs` pass-through.
`flake.nix` keeps `flake.modules` internal to evaluation and removes the public `modules` flake output so `nix flake check` stays warning-free.

Host distributions are composed from typed options (`sam.profile`, `sam.userConfig`) and role aspects from `variables.nix`, rather than passing host-specific `specialArgs` into reusable modules.

Roles are driven by `variables.nix`:

- `roles = [ "base" "laptop" "homelab-server" ]` for the control-plane laptop
- `roles = [ "base" "laptop" "homelab-agent" ]` for a worker node
- GUI-ness is not a role: it is gated on `sam.desktop.enable`, which lenovo sets in its default boot and acer-swift leaves false

## Commands

```bash
# Build and switch (Linux)
sudo nixos-rebuild switch --flake .#acer-swift
sudo nixos-rebuild switch --flake .#lenovo

# Test build without applying
sudo nixos-rebuild build --flake .#acer-swift

# Update all inputs
nix flake update

# Rollback if something breaks
sudo nixos-rebuild switch --rollback

# Garbage collection (manual)
nix-collect-garbage -d
```

## Validation

Use direct toplevel builds to validate host composition:

```bash
nix flake check --all-systems --no-write-lock-file
nix build .#nixosConfigurations.acer-swift.config.system.build.toplevel --no-link
nix build .#nixosConfigurations.lenovo.config.system.build.toplevel --no-link
```

## Codex

Codex is configured through `modules/programs/cli/codex/`.

- `~/.agents/skills/` receives the shared portable subset from the `claude-code-skills` input
- `~/.codex/skills/` mirrors that portable subset
- Home Manager activation then regenerates a Codex-local overlay from:
  - `~/knowledge/workflows/*/CONTEXT.md`
  - `~/claude-code-skills/skills/*/SKILL.md` entries not already present in the portable subset

That means a normal rebuild is enough to make new workspace workflows and Codex-compatible repo skills available:

```bash
sudo nixos-rebuild switch --flake .#<hostname>
```

No separate manual Codex sync step is required.

## Forking For Your Setup

Use this sequence to reproduce the same pattern in your own repo:

1. Fork/clone and rename host directories under `hosts/` for your machines.
2. Update identity defaults in `lib/users.nix` (git name/email, SSH keys).
3. Copy a host template (`hosts/acer-swift/` or `hosts/lenovo-21CB001PMX/`) and edit `variables.nix` and `configuration.nix`.
4. Add one distribution declaration per host in `flake-modules/hosts/<name>.nix`.
5. Keep reusable behavior in `modules/roles/*.nix` and `modules/core/*.nix`; avoid host-specific `specialArgs`.
6. If using secrets, update recipients in `secrets/.sops.yaml` and re-encrypt with `sops updatekeys`.
7. Run the validation commands above before every push.

## Pattern References

- https://github.com/hercules-ci/flake-parts
- https://flake.parts/options/flake-parts-modules.html
- https://github.com/mightyiam/dendritic
- https://discourse.nixos.org/t/dendrix-dendritic-nix-configurations-distribution/65853

## Remote Deploys (SSH)

From one Linux host, deploy to another host over SSH:

```bash
# Example: deploy acer-swift from lenovo
nixos-rebuild switch \
  --flake .#acer-swift \
  --target-host lukas@192.168.10.124 \
  --sudo \
  --ask-sudo-password
```

Notes:

- `--use-remote-sudo` is deprecated; use `--sudo`.
- Use `--ask-sudo-password` when remote sudo requires a password.
- If hostnames are flaky, target by IP.

Common failure:

```text
sudo: a terminal is required to read the password
```

Fix: rerun with `--ask-sudo-password`.

## SSH Hardening (Modular)

SSH security is centralized in reusable modules, with host-specific values in `hosts/<name>/variables.nix`.

- `modules/core/services.nix`
- `modules/core/network.nix`
- `modules/core/users.nix`

Current policy:

- Key-only SSH auth (`PasswordAuthentication = false`)
- No root SSH login (`PermitRootLogin = "no"`)
- Allowed SSH users are explicit (`AllowUsers = [ username ]`)
- SSH firewall policy allows only LAN CIDR + loopback
- Authorized keys come from `lib/users.nix` by default, with optional host override (`sshAuthorizedKeys`)

Per-host required variables:

```nix
# hosts/<name>/variables.nix
{
  username = "lukas";
}
```

Default source of SSH keys is `lib/users.nix`:

```nix
# lib/users.nix
{
  lukas.sshKeys = [
    "ssh-ed25519 AAAA... controller-key"
  ];
}
```

Optional per-host override (only when needed):

```nix
# hosts/<name>/variables.nix
{
  sshAuthorizedKeys = [
    "ssh-ed25519 AAAA... override-for-this-host-only"
  ];
  # Optional LAN override (default: 192.168.10.0/24)
  lanCidr = "192.168.20.0/24";
}
```

After changing SSH policy, always apply locally first on the target machine to avoid lockout:

```bash
sudo nixos-rebuild switch --flake .#<host>
```

## Automation

System auto-updates weekly (Sunday 06:00, plus up to 45 min of jitter), runs garbage collection monthly, and optimises the store weekly. Configured in `modules/core/automation.nix`. `acer-swift` forces `allowReboot = false` — it is the sole worker.

## Fresh Install (New Laptop)

Boot [NixOS ISO](https://nixos.org/download/#nixos-iso) (GNOME/Plasma for WiFi GUI), then:

```bash
nix-shell -p git
git clone <repo-url> /mnt/home/nixos-config && cd /mnt/home/nixos-config

# Create host config (copy from existing machine)
mkdir -p hosts/<name>
cp /mnt/etc/nixos/hardware-configuration.nix hosts/<name>/
cp hosts/acer-swift/{configuration.nix,variables.nix} hosts/<name>/
# Edit variables.nix + configuration.nix, then add a host declaration under flake-modules/hosts/
```

## Adding a New Machine

1. Create `hosts/<name>/` by copying an existing host
2. Update `variables.nix` (apps, desktop, hardware, SSH hardening vars)
3. Update `configuration.nix` if the hardware/roles differ
4. Add `flake-modules/hosts/<name>.nix` with `configurations.nixos.<flake-name>`
5. No registry edits are needed for Home Manager: every host shares `modules/home/default.nix` (auto-discovered by `flake-modules/20-module-registry.nix`)

Use `hosts/acer-swift` and `hosts/lenovo-21CB001PMX` as examples.

Minimum secure defaults for new hosts:

```nix
{
  username = "lukas";
  # hostname, desktop, hardware, roles...
}
```

SSH keys are inherited from `lib/users.nix` by default.

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
with lib;
let
  cfg = config.homelab.myservice;
in
{
  options.homelab.myservice.enable = mkEnableOption "My service";

  config = mkIf cfg.enable {
    # service config
  };
}
```

## Recommended New Host Workflow (Home Setup)

1. Install base NixOS from USB on the new host and ensure network + `sshd` are up.
2. From Lenovo, fetch the host SSH key and convert to age recipient:
   ```bash
   nix shell nixpkgs#ssh-to-age nixpkgs#openssh -c sh -c 'ssh-keyscan -t ed25519 <new-hostname-or-ip> 2>/dev/null | ssh-to-age'
   ```
3. Add that `age1...` recipient to `secrets/.sops.yaml` under `homelab/.*\.yaml$`.
4. Re-encrypt homelab secrets:
   ```bash
   cd secrets
   sops updatekeys -y homelab/k3s.yaml homelab/cloudflare.yaml
   ```
5. Commit secret recipient updates:
   ```bash
   cd ..
   git add secrets/.sops.yaml secrets/homelab/k3s.yaml secrets/homelab/cloudflare.yaml
   git commit -m "Add <new-host> SOPS recipient"
   ```
6. Add host files:
   - `hosts/<new-host>/variables.nix`
   - `hosts/<new-host>/configuration.nix`
   - `hosts/<new-host>/hardware-configuration.nix`
7. Register host in `flake-modules/hosts/<flake-host-name>.nix`.
8. Apply on the new host:
   ```bash
   sudo nixos-rebuild switch --flake .#<flake-host-name>
   ```
9. Verify decryption:
   ```bash
   sudo journalctl -u sops-nix -b --no-pager | tail -n 40
   ```

Only add secret-dependent roles (`homelab-server` / `homelab-agent`) after step 4 is done.

## Customization

| What | Where |
|------|-------|
| Theme & colors | [modules/themes/Catppuccin/default.nix](modules/themes/Catppuccin/default.nix) |
| Wallpaper | `assets/wallpapers/` |
| Git credentials | [lib/users.nix](lib/users.nix) |
| VSCode settings | [dotfiles/vscode/](dotfiles/vscode/) |
| Hyprland keybinds | [modules/desktop/hyprland/](modules/desktop/hyprland/) |
| Desktop stacks | `modules/specialisations/desktop.nix` and `modules/desktop/` |

## Learning Resources

These have been helpful in understanding Nix:

- [NixOS Manual](https://nixos.org/manual/nixos/stable/)
- [Home Manager Manual](https://nix-community.github.io/home-manager/)
- [Nix Pills](https://nixos.org/guides/nix-pills/) (language fundamentals)
- [Stylix](https://github.com/danth/stylix) (theming)
- [Hyprland Wiki](https://wiki.hyprland.org/)

## Inspiration

This setup is inspired by [Sly-Harvey/NixOS](https://github.com/Sly-Harvey/NixOS). Thanks for sharing a clean, modular reference repo.
