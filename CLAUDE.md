# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A NixOS + Home Manager configuration repository using **flake-parts** with a dendritic auto-discovery pattern. Manages Linux servers, laptops, and KubeVirt workstation images from a single flake.

## Build & Deploy Commands

```bash
# ── Verification (run before deploying) ────────────────────────────
just verify                   # Verify all physical hosts build successfully
just verify-all               # Verify all hosts including VM images
just check                    # Run flake checks (comprehensive validation)

# Or manually verify specific host:
nix build .#nixosConfigurations.<hostname>.config.system.build.toplevel --no-link

# ── Deployment ─────────────────────────────────────────────────────
# Build and apply locally (NixOS)
sudo nixos-rebuild switch --flake .#<hostname>

# Build without applying (dry run)
sudo nixos-rebuild build --flake .#<hostname>

# Remote deploy via SSH
nixos-rebuild switch --flake .#<hostname> --target-host lukas@<ip> --sudo --ask-sudo-password

# ── Workstation Images ─────────────────────────────────────────────
just build                    # Build qcow2 image
just publish [tag]            # Publish OCI containerDisk to Harbor
just release [tag]            # Build + publish
```

Current hostnames: `acer-swift`, `lenovo-21CB001PMX`, `msi-ms7758`, `workstation-template`

## Architecture

### Flake Entry Point

`flake.nix` is minimal (~49 lines). It recursively auto-imports all `.nix` files from `flake-modules/` using `collectFlakeModules`. The `flake-modules/` directory is numbered for load order:

- `00-flake-parts-modules.nix` — flake-parts setup
- `10-systems.nix` — supported systems
- `20-module-registry.nix` — auto-generates module registries from filesystem
- `30-configurations-options.nix` — typed host declaration options
- `40-outputs-nixos.nix` — transforms declarations into `nixosConfigurations`
- `hosts/<name>.nix` — per-host distribution declarations

### Module Registry (`20-module-registry.nix`)

Automatically generates `flake.modules` from filesystem conventions:
- `modules/roles/*.nix` → `flake.modules.nixos.role-<name>`
- `hosts/*/home.nix` → `flake.modules.homeManager.host-<dir>`

### Host Configuration Flow

Each host follows a 3–4 file pattern in `hosts/<name>/`:

| File | Purpose |
|------|---------|
| `variables.nix` | Plain attrset of host-specific choices (username, roles, videoDriver, monitors, etc.) |
| `configuration.nix` | NixOS system modules — imports `variables.nix`, sets `sam.profile` |
| `home.nix` | Home Manager config — imports CLI programs and optionally GUI programs |
| `hardware-configuration.nix` | Auto-generated hardware scan (physical machines only; omitted for virtual/image targets like `workstation-template`) |

The wiring: `flake-modules/hosts/<name>.nix` reads `variables.nix` and creates a typed `configurations.nixos.<name>` declaration. Then `40-outputs-nixos.nix` resolves roles to modules, injects Stylix/SOPS/Home Manager, and produces the final `nixosConfigurations.<name>`.

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

### Profile System (`sam.profile`)

Defined in `modules/core/system.nix`. All host metadata lives in `config.sam.profile` — a typed NixOS option submodule. Modules read this instead of using `specialArgs`.

**Available fields:**
- `username` (str) — Primary user account
- `hostname` (str) — System hostname
- `videoDriver` (str) — GPU driver: "intel", "nvidia-kepler", "nvidia-modern", "amd", or null
- `monitors` (list of attrset) — Monitor configuration for Hyprland (name, width, height, refreshRate, x, y, scale)
- `roles` (list of str) — Enabled roles from `modules/roles/`
- `laptop` (bool) — Laptop-specific settings enabled
- `games` (bool) — Gaming packages enabled
- `lanCidr` (str) — LAN subnet for firewall rules (default: "192.168.10.0/24")
- `sshAuthorizedKeys` (list of str) — Authorized SSH public keys
- `guiPrograms` (bool) — GUI applications enabled (set via specialisation)
- `hyprlandMonitors` (list of str) — Generated Hyprland monitor config strings
- `homeManagerBackpackGlobs` (list of str) — Backpack file patterns for Home Manager
- `homeManagerModules` (list of module) — Additional Home Manager modules to import

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
├── desktop/      # Desktop stack: hyprland/ (Wayland compositor)
├── hardware/     # GPU drivers (intel, nvidia-kepler, nvidia-modern, amd), thermal
├── homelab/      # k3s (agent/server), sops, flux, tailscale, workstation-image
├── programs/     # Home Manager programs: cli/, browser/, editor/, terminal/
├── roles/        # Composition roles (see above)
└── themes/       # Catppuccin via Stylix
```

### Secrets

SOPS-nix with age-based encryption. Config in `secrets/.sops.yaml`. Secrets decrypt at boot to `/run/secrets/`.

Two SOPS modules:
- **`modules/homelab/sops.nix`** (`homelab.secrets.enable`) — k3s cluster tokens, Flux deploy keys, Cloudflare API token. Encrypted to all host keys + Flux age key.
- **`modules/core/sops.nix`** (`sam.secrets.enable`) — shared secrets for all physical hosts (Claude Code OAuth token). Uses `mkDefault` for age config to avoid conflicts with the homelab module.

Secret scopes in `secrets/.sops.yaml`:

| Path pattern | Recipients | Purpose |
|--------------|-----------|---------|
| `homelab/*.yaml` | Personal + 3 hosts + Flux | k3s, Cloudflare, Flux keys, Tailscale authkey |
| `claude/*.yaml` | Personal + 3 hosts | Claude Code OAuth token |

The `CLAUDE_CODE_OAUTH_TOKEN` is decrypted to `/run/secrets/claude_oauth_token` and exported in bash shell init via `modules/programs/cli/claude-code/mcp.nix`. The workstation-template VM is unaffected — it receives its token via cloud-init at `/etc/workstation/agent-env`.

### Claude Code

Configuration lives in `modules/programs/cli/claude-code/`:

| File | Scope | Purpose |
|------|-------|---------|
| `mcp.nix` | All NixOS hosts (shared HM module) | Settings, plugins, MCP servers, shebang fixes, SOPS token sourcing |
| `default.nix` | `workstation-template` only | Headless agent config, Justfile, heartbeat service, cloud-init env sourcing |
| `skills.nix` | All NixOS hosts (shared HM module) | Symlinks skills and agents from the `claude-code-skills` flake input |

**Plugin configuration** (`mcp.nix`): Declares `enabledPlugins` (superpowers, ralph-loop, playwright, superpowers-lab) and MCP servers (playwright/chromium) in `programs.claude-code.settings`.

**Personal skills and agents** are managed via the [`sammasak/claude-code-skills`](https://github.com/sammasak/claude-code-skills) repo, added as a non-flake input (`flake = false`). The `skills.nix` module auto-discovers all directories in `skills/` and `.md` files in `agents/` from that input and creates Home Manager symlinks:

- `skills/<name>/SKILL.md` → `~/.claude/skills/<name>/SKILL.md`
- `agents/<name>.md` → `~/.claude/agents/<name>.md`

These are available across all projects without manual `/plugin install`.

**Update workflow**:
```bash
# In ~/claude-code-skills: add/edit skills or agents, push to GitHub
# In ~/nixos-config:
nix flake update claude-code-skills
sudo nixos-rebuild switch --flake .#<hostname>
```

### Tailscale Remote Access

**Purpose:** Secure remote access to homelab LAN (192.168.10.0/24) from anywhere via Tailscale VPN subnet routing.

**Configuration:** `modules/homelab/tailscale.nix`

**Enabled on:** Control-plane node (`lenovo-21CB001PMX`) via `homelab-server` role

**Key features:**
- **Subnet routing** — Advertises 192.168.10.0/24 to the Tailscale network
- **MagicDNS integration** — Uses AdGuard Home (192.168.10.154) for `*.sammasak.dev` DNS resolution
- **SOPS-encrypted authkey** — Stored in `secrets/homelab/tailscale.yaml`
- **IP forwarding** — Enables kernel forwarding for subnet routes
- **Firewall integration** — Trusts `tailscale0` interface

**Module options** (`homelab.tailscale.*`):
- `enable` (bool) — Enable Tailscale subnet router
- `subnetRoutes` (list of str) — Subnets to advertise (defaults to `sam.profile.lanCidr`)
- `authKeyFile` (path) — Path to SOPS-decrypted authkey (default: `/run/secrets/tailscale-authkey`)

**How it works:**
1. `tailscaled.service` starts at boot
2. `tailscale-subnet-router.service` runs once to configure:
   - Authenticates using authkey from SOPS
   - Advertises subnet routes
   - Enables SSH access via Tailscale
3. Admin must approve subnet routes in Tailscale admin console
4. Tailscale clients can access homelab LAN IPs and services

**DNS flow:**
- Client queries `grafana.sammasak.dev`
- Tailscale MagicDNS forwards to AdGuard Home (192.168.10.154)
- AdGuard returns internal IP (e.g., 192.168.10.200)
- Traffic routes through control-plane subnet router

**Documentation:**
- Setup checklist: `~/knowledge-vault/Homelab/Projects/tailscale-integration/HUMAN_ACTION_REQUIRED.md`
- Operations runbook: `~/knowledge-vault/Homelab/Runbooks/tailscale-operations.md`

### Key Inputs

nixpkgs (unstable), flake-parts, home-manager, stylix, sops-nix, claude-code-skills — all following nixpkgs (except claude-code-skills which is a plain source input).

## Conventions

- **No specialArgs**: Host data flows through `sam.profile` typed options, not `specialArgs` pass-through.
- **Desktop via specialisation**: Hosts with Intel GPUs get an optional desktop boot entry; all hosts boot to server mode by default.
- **User identity**: `lib/users.nix` holds git config and SSH keys, referenced as `sam.userConfig`.
- **Firewall**: LAN CIDR defaults to `192.168.10.0/24` (override via `sam.profile.lanCidr`). SSH is key-only, no root login.
- **stateVersion**: Set to `25.11` in `core/system.nix`.

## Adding a New Host

1. Create `hosts/<name>/` with `variables.nix`, `configuration.nix`, `home.nix`, `hardware-configuration.nix`
2. Create `flake-modules/hosts/<name>.nix` declaring `configurations.nixos.<name>` (reads variables, sets system/username/roles)
3. The module registry auto-discovers the rest

See [[Infrastructure/Runbooks/add-new-host]] in knowledge-vault for detailed instructions.

## Further Documentation

Additional documentation is maintained in the knowledge-vault (~/Documents/knowledge-vault):

**Infrastructure Concepts:**
- [[Infrastructure/Concepts/nixos-modules]] - NixOS declarative configuration
- [[Infrastructure/Concepts/nix-specialisations]] - Boot-time system variants
- [[Infrastructure/Concepts/k3s-nixos]] - Lightweight Kubernetes on NixOS
- [[Infrastructure/Concepts/flux-gitops]] - GitOps continuous deployment
- [[Infrastructure/Concepts/sops-nixos]] - Secrets management with SOPS
- [[Infrastructure/Concepts/age-encryption]] - Modern encryption with age

**Infrastructure Runbooks:**
- [[Infrastructure/Runbooks/bootstrap-homelab]] - Complete cluster bootstrap guide
- [[Infrastructure/Runbooks/add-new-host]] - Adding new NixOS hosts

**Architecture Overviews:**
- [[Infrastructure/Architecture/homelab-platform-overview]] - Homelab platform architecture
