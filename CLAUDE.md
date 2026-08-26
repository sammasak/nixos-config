# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A NixOS + Home Manager configuration repository using **flake-parts** with a dendritic auto-discovery pattern. Manages Linux servers and laptops from a single flake.

## Build & Deploy Commands

```bash
# ── Verification (run before deploying) ────────────────────────────
just verify                   # Verify all hosts build successfully
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
```

Current hostnames: `acer-swift`, `lenovo-21CB001PMX` (flake attribute `lenovo`)

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

Desktop mode (Hyprland + SDDM + Waybar/Rofi/theming + GUI apps) and headless
server mode are boot-menu variants. **The default differs per host** — each one
boots into whichever mode it spends most of its life in, and carries the other
as a specialisation:

| Host | Default boot | Specialisations |
|------|--------------|-----------------|
| `lenovo-21CB001PMX` | **desktop** (daily-driver laptop, also the k3s control plane) | `server` (headless), `niri` (compositor trial) |
| `acer-swift` | **server** (headless k3s worker) | `desktop` |

Boot menu on lenovo, for example:
```
NixOS (default)  ← Desktop mode
NixOS - server   ← Headless
NixOS - niri     ← Desktop mode, niri compositor instead of Hyprland
```

**One signal decides GUI-ness:** `sam.desktop.enable`. It is set by
`modules/specialisations/desktop.nix` and force-cleared by
`modules/specialisations/server.nix`. Fonts, GUI packages, desktop services and
the Home Manager desktop imports all key off it. Do not gate new desktop-only
config on `programs.hyprland.enable` — that ties it to one compositor.

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

Sibling option, outside the profile because specialisations set it:
- `sam.desktop.enable` (bool) — whether a GUI desktop session is active

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
├── hardware/     # GPU drivers (intel), thermal
├── homelab/      # k3s (agent/server), sops, flux, tailscale, ntfy, watchdog
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
| `homelab/*.yaml` | Personal + 2 hosts + Flux | k3s, Cloudflare, Flux keys, Tailscale authkey |
| `claude/*.yaml` | Personal + 2 hosts | Claude Code OAuth token |

The `CLAUDE_CODE_OAUTH_TOKEN` is decrypted to `/run/secrets/claude_oauth_token` and exported in bash shell init via `modules/programs/cli/claude-code/mcp.nix`.

### Claude Code

Configuration lives in `modules/programs/cli/claude-code/`:

| File | Scope | Purpose |
|------|-------|---------|
| `mcp.nix` | All NixOS hosts (shared HM module) | Settings, plugins, MCP servers, shebang fixes, SOPS token sourcing |
| `default.nix` | All NixOS hosts (shared HM module) | Headless-agent settings, `~/Justfile` agent recipes, heartbeat unit. Written for the retired VM images and still applied everywhere; see "Known residue" below |
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

### Codex

Configuration lives in `modules/programs/cli/codex/`:

| File | Scope | Purpose |
|------|-------|---------|
| `default.nix` | All NixOS hosts (shared HM module) | Codex config, hooks, shared skill links, activation-time skill sync |
| `context-hook.sh` | All NixOS hosts | Injects workspace routing hints for `~/knowledge`, workflows, and `claude-code-skills` |
| `validate-bash.sh` | All NixOS hosts | Blocks force pushes and other unsafe bash patterns |
| `sync-codex-skills.sh` | All NixOS hosts | Regenerates Codex-local workflow/repo skill wrappers after each activation |
| `workspace-routing/` | All NixOS hosts | Base Codex skill for ICM workspace routing |

**Skill delivery model**:
- `~/.agents/skills/` holds the shared portable subset from the `claude-code-skills` flake input
- `~/.codex/skills/` mirrors that portable subset for compatibility
- `sync-codex-skills.sh` then overlays Codex-local wrappers for:
  - canonical workspace workflows from `~/knowledge/workflows/*/CONTEXT.md`
  - repo-only skills from `~/claude-code-skills/skills/*/SKILL.md` that are not already in the shared portable subset

The overlay is regenerated automatically by Home Manager activation on every rebuild. No manual Codex skill sync step is required after `nixos-rebuild switch`.

### Tailscale Remote Access

**Purpose:** Secure remote access to homelab LAN (192.168.10.0/24) from anywhere via Tailscale VPN subnet routing.

**Configuration:** `modules/homelab/tailscale.nix`

**Enabled on:** every homelab node, in one of two modes.

| Role | Mode | Behaviour |
|------|------|-----------|
| `homelab-server` (`lenovo-21CB001PMX`) | `subnet-router` | Advertises the LAN CIDR, accepts routes, enables Tailscale SSH |
| `homelab-agent` (`acer-swift`) | `client` | Joins the tailnet only — no advertised routes, `--accept-routes=false`, `--accept-dns=false`, no Tailscale SSH |

Workers run a direct client so that remote access to them does not die with the
control plane. They deliberately do **not** accept routes or DNS: they already
sit on the LAN, so accepting the router's own subnet would push their LAN
traffic back through the control plane and recreate the dependency. sshd stays
the only shell boundary on workers.

**Key features:**
- **Subnet routing** (subnet-router mode) — Advertises 192.168.10.0/24 to the Tailscale network
- **MagicDNS integration** (subnet-router mode) — Uses AdGuard Home (192.168.10.154) for `*.sammasak.dev` DNS resolution
- **SOPS-encrypted authkey** — Stored in `secrets/homelab/tailscale.yaml`, encrypted to both host keys
- **IP forwarding** — Enabled for subnet routes (subnet-router mode only)
- **Firewall integration** — Trusts `tailscale0` interface

**Module options** (`homelab.tailscale.*`):
- `enable` (bool) — Enable Tailscale
- `mode` (enum `subnet-router` | `client`) — Node behaviour, default `subnet-router`
- `subnetRoutes` (list of str) — Subnets to advertise, subnet-router mode only (defaults to `sam.profile.lanCidr`)
- `authKeyFile` (path) — Path to SOPS-decrypted authkey (default: `/run/secrets/tailscale-authkey`)

**How it works:**
1. `tailscaled.service` starts at boot
2. `tailscale-autoconnect.service` runs once to configure:
   - Authenticates using the authkey from SOPS, but only if not already authenticated
     (re-using a consumed single-use key fails)
   - Applies the mode's preferences
3. Admin must approve subnet routes in the Tailscale admin console
4. Tailscale clients can access homelab LAN IPs and services

If `tailscale-autoconnect` fails, the usual cause is an expired or already-consumed
authkey: mint a new one in the admin console, update `secrets/homelab/tailscale.yaml`,
rebuild, then `systemctl start tailscale-autoconnect`.

**DNS flow:**
- Client queries `grafana.sammasak.dev`
- Tailscale MagicDNS forwards to AdGuard Home (192.168.10.154)
- AdGuard returns internal IP (e.g., 192.168.10.200)
- Traffic routes through control-plane subnet router

**Documentation:**
- Setup checklist: `~/knowledge/Homelab/Projects/tailscale-integration/HUMAN_ACTION_REQUIRED.md`
- Operations runbook: `~/knowledge/Homelab/Runbooks/tailscale-operations.md`

### Key Inputs

nixpkgs (unstable), flake-parts, home-manager, stylix, sops-nix, claude-code-skills — all following nixpkgs (except claude-code-skills which is a plain source input).

### Known residue: the retired VM image platform

The KubeVirt workstation / claude-worker VM images were retired in 2026-08. The
hosts (`workstation-template`, `claude-worker-template`), their image modules,
the build/publish scripts and the `just build`/`publish`/`release` targets are
gone. `pkgs/claude-ctl.nix`, the `claude-ctl` flake input and its overlay wiring
were removed on 2026-08-26. Two things still survive the cull because they are
wired into physical hosts and removing them is a behaviour change, not a
deletion:

| What | Why it is still here | Why it is dead weight |
|------|---------------------|----------------------|
| `modules/programs/cli/claude-code/default.nix` | Listed in `sharedModules` in `40-outputs-nixos.nix`, so it applies to every host. Also sets `programs.claude-code.settings.permissions` | Writes a `~/Justfile` of VM agent recipes, sources `/etc/workstation/agent-env`, and defines an `agent-heartbeat` user unit that annotates a `WorkspaceClaim` in the deleted `workstations` namespace. The unit has no `Install` section, so it never auto-starts |
| `modules/programs/cli/codex/validate-bash.sh` | Shared Codex hook | Two of its rules only fire inside `/var/lib/claude-worker`, which no longer exists anywhere |

Removing these two is a reasonable follow-up; it needs a decision about the
permissions block, so it was kept out of the retirement commit.

## Conventions

- **No specialArgs**: Host data flows through `sam.profile` typed options, not `specialArgs` pass-through.
- **Desktop via specialisation**: desktop and server are boot-menu variants; the default is per-host (lenovo boots desktop, acer-swift boots server). Gate GUI config on `sam.desktop.enable`.
- **User identity**: `lib/users.nix` holds git config and SSH keys, referenced as `sam.userConfig`.
- **Firewall**: LAN CIDR defaults to `192.168.10.0/24` (override via `sam.profile.lanCidr`). SSH is key-only, no root login.
- **stateVersion**: Set to `25.11` in `core/system.nix`.

## Adding a New Host

1. Create `hosts/<name>/` with `variables.nix`, `configuration.nix`, `hardware-configuration.nix` (Home Manager is shared — no per-host `home.nix`)
2. Create `flake-modules/hosts/<name>.nix` declaring `configurations.nixos.<name>` (reads variables, sets system/username/roles)
3. The module registry auto-discovers the rest

See [[Infrastructure/Runbooks/add-new-host]] in knowledge for detailed instructions.

## Further Documentation

Additional documentation is maintained in the knowledge (~/knowledge):

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
