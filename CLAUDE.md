# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A NixOS + Home Manager configuration repository using **flake-parts** with a dendritic auto-discovery pattern. Manages Linux servers and laptops from a single flake.

## Build & Deploy Commands

```bash
# ── Verification (run before deploying) ────────────────────────────
just verify                   # Verify all hosts build successfully
just check                    # Both lints + secrets gate, then flake checks
just lint-comments            # Comment Policy only (density + forbidden shapes)
just lint-shell               # Shellcheck scripts/*.sh
just secrets-verify           # Sanity-check decrypted wifi credentials (skips without an age key)

# Or manually verify specific host:
nix build .#nixosConfigurations.<hostname>.config.system.build.toplevel --no-link

# ── Deployment (switch is plain nixos-rebuild; build/diff use nh) ──
just switch [HOST]            # Build and activate
just build  [HOST]            # Build only
just diff   [HOST]            # Build and print the package diff vs the running system

# Remote deploy via SSH
nixos-rebuild switch --flake .#<hostname> --target-host lukas@<ip> --sudo --ask-sudo-password
```

Current hostnames: `acer-swift`, `lenovo-21CB001PMX` (flake attribute `lenovo`), and `msi-ms7758`.
`HOST` is the **flake attribute**, which for lenovo is not its hostname — the
`host` variable at the top of the Justfile does that mapping, so the argument is
only needed when targeting the other machine.

## Architecture

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

### Secrets

SOPS-nix with age-based encryption. Config in `secrets/.sops.yaml`. Secrets decrypt at boot to `/run/secrets/`.

Two SOPS modules:
- **`modules/homelab/sops.nix`** (`homelab.secrets.enable`) — k3s cluster tokens, Flux deploy keys, Cloudflare API token. Encrypted to all host keys + Flux age key.
- **`modules/core/sops.nix`** (`sam.hostSecrets.enable`) — per-machine operator credentials on every physical host (Claude Code OAuth token, nix access token). Uses `mkDefault` for age config to avoid conflicts with the homelab module.

Secret scopes in `secrets/.sops.yaml`:

| Path pattern | Recipients | Purpose |
|--------------|-----------|---------|
| `homelab/*.yaml` | Personal + 2 hosts + Flux | k3s, Cloudflare, Flux keys, Tailscale authkey |
| `claude/*.yaml` | Personal + 2 hosts | Claude Code OAuth token |
| `cosign.key` | Personal only | Image-signing key used by `just sign` |

The `CLAUDE_CODE_OAUTH_TOKEN` is decrypted to `/run/secrets/claude_oauth_token` and exported in fish shell init via `modules/programs/cli/claude-code/mcp.nix`.

### Claude Code

Configuration lives in `modules/programs/cli/claude-code/`:

| File | Scope | Purpose |
|------|-------|---------|
| `mcp.nix` | All NixOS hosts (shared HM module) | Settings, plugins, MCP servers, shebang fixes, SOPS token sourcing |
| `default.nix` | All NixOS hosts (shared HM module) | First-boot `~/.claude.json` seed, tool-permissions block, `programs.fish.enable` |
| `skills.nix` | All NixOS hosts (shared HM module) | Symlinks skills and agents from the `claude-code-skills` flake input |

**Plugin configuration** (`mcp.nix`): Declares `enabledPlugins` (superpowers, rust-analyzer-lsp, frontend-design, code-simplifier) and MCP servers (playwright/chromium) in `programs.claude-code.settings`.

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

`modules/homelab/tailscale.nix` (`homelab.tailscale.*`): lenovo is the
subnet-router for the LAN; acer runs **no client** (owner decision
2026-08-26 — remote access rides lenovo, and lenovo-death needs physical
recovery anyway). Features, DNS flow, and auth-state handling:
`~/knowledge/homelab/runbooks/tailscale-operations.md`.

The one gotcha worth carrying here: a dead tailnet can hold deploys hostage
(the wanted unit is *started* by every switch); recovery steps are in the
runbook above — never rotate the authkey while an auth URL is pending.

### Key Inputs

nixpkgs (unstable), flake-parts, home-manager, stylix, sops-nix, claude-code-skills — all following nixpkgs (except claude-code-skills which is a plain source input).

## Comment Policy

Nix is declarative: the option name and value already say *what*. A comment
earns its line only by saying something the code cannot. Write one only when it
is one of these four:

| Allowed | Example |
|---------|---------|
| **(a) A consequence or gotcha** — what breaks, and when | `# NOT security.lockKernelModules: it breaks on-demand module loading for k3s/containerd.` |
| **(b) An upstream doc link** | `# https://wiki.hyprland.org/Configuring/Variables/#input` |
| **(c) A FIXME with the specific blocker** | `# FIXME: waiting on nixpkgs#123456; the module asserts on empty extraCommands.` |
| **(d) A one-line justification for a pin or override** | `# mkForce: the desktop module sets this too and we must win.` |
| **(e) A file header, only when it carries a fact the path does not** | `# Common k3s configuration shared between server and agent` |

Never:

- restate the option (`# Enable the firewall` above `firewall.enable = true`)
- carry incident history, dates, or a ticket number used as narrative (a dated
  *revisit trigger* — "revisit if X breaks" — is a consequence, and is fine)
- explain how to restore something you deleted — `git log` owns that, and a
  commit message is the right place for the why of a deletion
- keep a commented-out config block "in case"
- head a file with its own path (`# Boot configuration` in `core/boot.nix`)
- label a single setting with its own name (`# Cursor` above `cursor_shape`)

One exception to the last point: a bare label heading **four or more** related
entries in a long flat list — `packages.nix`'s groups, hyprland's keybind
sections — is navigation, not restatement, and stays.

Long rationale goes to the knowledge vault, and the code keeps a single pointer:

```nix
# <one-line why>. See vault: <file>.md
```

The pointer must name a file that **exists**. Check before you write it; the
board prune of 2026-08-25 left several in-code references to deleted tickets
pointing at nothing.

Target band 7–13% comment density; `just lint-comments` is the enforced floor
(fails any 30+ nix-code-line `.nix` file above **25%**, plus the never-allowed
shapes, across `.nix` and `.sh` alike). `''` string bodies are out of scope —
editing one moves the derivation and breaks `just parity`. Exemplar comments,
the `''`-string rationale, and measurement mechanics:
`~/knowledge/nix/comment-policy-notes.md`.

## Conventions

- **Namespace boundary**: `homelab.*` is a cluster/platform capability a host
  opts into (k3s, flux, dns, acme, ntfy, tailscale, the rebuild trigger);
  `sam.*` is host identity and personal-machine concern (profile, desktop,
  wifi, thermal, hostSecrets). When both scopes need the same noun, the leaf
  states its scope — `homelab.secrets` (cluster) vs `sam.hostSecrets` (machine)
  — because an option path is usually read without its module.
- **No specialArgs**: Host data flows through `sam.profile` typed options, not `specialArgs` pass-through.
- **Desktop is per-host, not a role**: Lenovo imports `modules/specialisations/desktop.nix` in its default boot; Acer imports it as an optional specialisation. Gate GUI config on `sam.desktop.enable`.
- **User identity**: `lib/users.nix` holds git config and SSH keys, referenced as `sam.userConfig`.
- **Firewall**: LAN CIDR defaults to `192.168.10.0/24` (override via `sam.profile.lanCidr`). SSH is key-only, no root login.
- **Unfree is opt-in**: `nixpkgs.config.allowUnfree` is `false`. Adding an unfree package means adding its name to `allowUnfreePredicate` in `core/system.nix` (currently claude-code, obsidian, unrar, vscode) — otherwise eval fails and names it. Redistributable firmware is unaffected (separate nixpkgs knob).
- **Workers are not trusted-users**: `modules/roles/homelab-agent.nix` forces `nix.settings.trusted-users = [ "root" ]`. Deploys are push-from-lenovo; lenovo itself keeps `root` + `lukas` from `core/users.nix`.
- **stateVersion**: Set to `25.11` in `core/system.nix`.

## Adding a New Host

`hosts/<name>/` (variables + configuration + hardware scan) plus
`flake-modules/hosts/<name>.nix`; the registry auto-discovers the rest.
Full procedure: `~/knowledge/homelab/runbooks/add-new-host.md`.

## Further Documentation

The vault (`~/knowledge`) owns concepts, runbooks, and ADRs for everything
this repo touches — route via `~/knowledge/CLAUDE.md`; start at `nix/` for
NixOS concepts and `homelab/` for runbooks and decisions (ADR-024 rebuild
trigger and ADR-025 kernel choice are referenced from code here).
