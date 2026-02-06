# NixOS Configuration

Personal NixOS + nix-darwin + Home Manager configuration. A work in progress as I learn the Nix ecosystem.

## Goals

- Unified config across Linux desktops, servers, and macOS
- Single user config that adapts to each machine type
- Reproducible, declarative system management
- Learn Nix patterns and best practices along the way

## Current Machines

| Machine | Type | Status |
|---------|------|--------|
| `acer-swift` | Linux laptop (Hyprland) | Active |
| `lenovo-21CB001PMX` | Linux laptop (Hyprland) | Active |
| `work-mac` | macOS (CLI only) | Planned |

## Structure

```
flake.nix                # Entry point, host definitions
├── hosts/               # Per-machine configs
│   ├── acer-swift/
│   │   ├── configuration.nix
│   │   ├── hardware-configuration.nix
│   │   ├── home.nix
│   │   └── variables.nix
│   └── lenovo-21CB001PMX/
│       ├── configuration.nix
│       ├── hardware-configuration.nix
│       ├── home.nix
│       └── variables.nix
├── modules/             # Reusable modules
│   ├── core/            # System baseline (nix, users, services, fonts)
│   ├── desktop/         # Desktop stacks (Hyprland)
│   ├── hardware/        # Hardware drivers
│   ├── programs/        # Home Manager program modules
│   ├── roles/           # Base/desktop/laptop composition
│   └── themes/          # Theme definitions
├── darwin/              # macOS system configuration
│   └── common.nix
├── home/                # Home Manager entrypoints
│   └── lukas.nix        # darwin CLI profile
├── lib/                 # Shared helpers (users, theme)
├── assets/              # Wallpapers and other assets
├── dotfiles/            # Plain config files (symlinked)
├── secrets/             # Secrets (handled out-of-band)
└── tmp/                 # Local comparison/scratch (gitignored)
```

## How It Works

Each host lives in `hosts/<name>/` and provides:

- `variables.nix`: choices for desktop, theme, apps, hardware
- `configuration.nix`: system modules for that host
- `home.nix`: Home Manager modules for that host

[flake.nix](flake.nix) wires `mkHost` to load those files, pass `host`/`user` to modules, and share common building blocks in `modules/`. macOS uses `darwin/common.nix` plus the `home/lukas.nix` CLI profile.

Roles are driven by `variables.nix`:

- `roles = [ "base" "laptop" "desktop" ]` for laptops
- Drop `"desktop"` for headless machines to keep the same shell/CLI baseline without a GUI

## Commands

```bash
# Build and switch (Linux)
sudo nixos-rebuild switch --flake .#acer-swift
sudo nixos-rebuild switch --flake .#lenovo

# Test build without applying
sudo nixos-rebuild build --flake .#acer-swift

# Update all inputs
nix flake update

# macOS (first time - installs nix-darwin)
nix run nix-darwin -- switch --flake .#work-mac

# macOS (subsequent)
darwin-rebuild switch --flake .#work-mac

# Rollback if something breaks
sudo nixos-rebuild switch --rollback

# Garbage collection (manual)
nix-collect-garbage -d
```

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
- Authorized keys come from host variables (`sshAuthorizedKeys`)

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

System auto-updates weekly (Sunday 3 AM), runs garbage collection monthly, and optimizes the store weekly. Configured in `modules/core/automation.nix`.

## Fresh Install (New Laptop)

Boot [NixOS ISO](https://nixos.org/download/#nixos-iso) (GNOME/Plasma for WiFi GUI), then:

```bash
nix-shell -p git
git clone <repo-url> /mnt/home/nixos-config && cd /mnt/home/nixos-config

# Create host config (copy from existing machine)
mkdir -p hosts/<name>
cp /mnt/etc/nixos/hardware-configuration.nix hosts/<name>/
cp hosts/acer-swift/{configuration.nix,home.nix,variables.nix} hosts/<name>/
# Edit variables.nix + configuration.nix, then add the host to flake.nix
```

## Adding a New Machine

1. Create `hosts/<name>/` by copying an existing host
2. Update `variables.nix` (apps, desktop, hardware, SSH hardening vars)
3. Update `configuration.nix` if the hardware/roles differ
4. Add the host entry in [flake.nix](flake.nix)

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
   - `hosts/<new-host>/home.nix`
   - `hosts/<new-host>/hardware-configuration.nix`
7. Register host in `flake.nix` (`nixosConfigurations`).
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

## Learning Resources

These have been helpful in understanding Nix:

- [NixOS Manual](https://nixos.org/manual/nixos/stable/)
- [Home Manager Manual](https://nix-community.github.io/home-manager/)
- [nix-darwin](https://github.com/nix-darwin/nix-darwin)
- [Nix Pills](https://nixos.org/guides/nix-pills/) (language fundamentals)
- [Stylix](https://github.com/danth/stylix) (theming)
- [Hyprland Wiki](https://wiki.hyprland.org/)

## Inspiration

This setup is inspired by [Sly-Harvey/NixOS](https://github.com/Sly-Harvey/NixOS). Thanks for sharing a clean, modular reference repo.
