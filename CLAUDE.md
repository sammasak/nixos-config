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

# ── Deployment (nh wraps nixos-rebuild + nvd) ──────────────────────
just switch [HOST]            # Build and activate
just build  [HOST]            # Build only
just diff   [HOST]            # Build and print the package diff vs the running system

# Remote deploy via SSH
nixos-rebuild switch --flake .#<hostname> --target-host lukas@<ip> --sudo --ask-sudo-password
```

Current hostnames: `acer-swift`, `lenovo-21CB001PMX` (flake attribute `lenovo`).
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
| `lenovo-21CB001PMX` | **desktop** (daily-driver laptop, also the k3s control plane) | `niri` (compositor trial) |
| `acer-swift` | **headless** (k3s worker) | none |

Boot menu on lenovo:
```
NixOS (default)  ← Desktop mode
NixOS - niri     ← Desktop mode, niri compositor instead of Hyprland
```

The niri entry sets `defaultSession = "niri"`, but SDDM's remembered
`Last.Session` (`/var/lib/sddm/state.conf`, shared across boot entries) beats
`DefaultSession` whenever the remembered session exists in the booted entry —
and `hyprland.desktop` exists in both. So the niri entry pre-selects Hyprland
until niri is picked once in the greeter; the base entry always falls back to
Hyprland because it has no `niri.desktop`.

The cross-mode specialisations were removed on 2026-08-27: lenovo's `server`
entry (and `modules/specialisations/server.nix` with it) and acer-swift's
`desktop` entry. Neither had been booted, and each cost a second full system
closure on every rebuild — about 5 GiB on the worker. To restore either, read
the removal commit; per the Comment Policy the host files do not carry undo
instructions.

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
- **`modules/core/sops.nix`** (`sam.hostSecrets.enable`) — per-machine operator credentials on every physical host (Claude Code OAuth token, nix access token). Uses `mkDefault` for age config to avoid conflicts with the homelab module.

Secret scopes in `secrets/.sops.yaml`:

| Path pattern | Recipients | Purpose |
|--------------|-----------|---------|
| `homelab/*.yaml` | Personal + 2 hosts + Flux | k3s, Cloudflare, Flux keys, Tailscale authkey |
| `claude/*.yaml` | Personal + 2 hosts | Claude Code OAuth token |
| `cosign.key` | Personal only | Image-signing key used by `just sign` |

The `CLAUDE_CODE_OAUTH_TOKEN` is decrypted to `/run/secrets/claude_oauth_token` and exported in bash shell init via `modules/programs/cli/claude-code/mcp.nix`.

### Claude Code

Configuration lives in `modules/programs/cli/claude-code/`:

| File | Scope | Purpose |
|------|-------|---------|
| `mcp.nix` | All NixOS hosts (shared HM module) | Settings, plugins, MCP servers, shebang fixes, SOPS token sourcing |
| `default.nix` | All NixOS hosts (shared HM module) | First-boot `~/.claude.json` seed, tool-permissions block, `programs.fish.enable` |
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
| `homelab-agent` (`acer-swift`) | — (none) | **No Tailscale client — owner decision 2026-08-26.** Remote access rides the lenovo subnet router; the lenovo-death edge case needs physical recovery anyway (vault: `homelab/runbooks/lenovo-death-recovery.md`). Client-mode machinery stays in the module if ever revisited |

`modules/roles/homelab-agent.nix` imports `modules/homelab/tailscale.nix` but
never sets `homelab.tailscale.enable`, so the import is inert on workers.

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
   - If an interactive re-auth is already pending (node-key expiry mints an auth
     URL at boot), it logs that URL, pages ntfy, and exits 0 instead of stomping
     the URL with the stored key
   - Applies the mode's preferences
3. Admin must approve subnet routes in the Tailscale admin console
4. Tailscale clients can access homelab LAN IPs and services

Operator-actionable auth states (pending auth URL, dead authkey) page ntfy,
log to the journal and exit 0 — a failed wanted unit is *started* (not
restarted, so `restartIfChanged` cannot help) by every switch and fails whole
activations (the rebuild trigger then rolls back), holding deploys hostage to
tailnet auth state. So when the tailnet is down, read
`journalctl -u tailscale-autoconnect`: "Interactive re-auth already pending"
means finish the printed auth URL in a browser (do NOT rotate the authkey);
the authkey message means mint a new key in the admin console, update
`secrets/homelab/tailscale.yaml`, rebuild, then
`systemctl restart tailscale-autoconnect` (restart, not start — the unit
stays `active (exited)` after the clean exit). The unit only *fails* when
reapplying preferences on an authenticated node errors.

**DNS flow:**
- Client queries `grafana.sammasak.dev`
- Tailscale MagicDNS forwards to AdGuard Home (192.168.10.154)
- AdGuard returns internal IP (e.g., 192.168.10.200)
- Traffic routes through control-plane subnet router

**Documentation:**
- Operations runbook: `~/knowledge/homelab/runbooks/tailscale-operations.md`

### Key Inputs

nixpkgs (unstable), flake-parts, home-manager, stylix, sops-nix, claude-code-skills — all following nixpkgs (except claude-code-skills which is a plain source input).

### Known residue: the retired VM image platform

The KubeVirt workstation / claude-worker VM images were retired in 2026-08. The
hosts (`workstation-template`, `claude-worker-template`), their image modules,
the build/publish scripts and the `publish`/`release` targets are gone.
`pkgs/claude-ctl.nix`, the `claude-ctl` flake input and its overlay wiring were
removed on 2026-08-26. The `just build` recipe that exists today is unrelated —
it builds a NixOS system, not a VM image.

The VM scaffolding inside `modules/programs/cli/claude-code/default.nix` — the
`~/Justfile` of agent recipes, the `agent-heartbeat` user unit pointing at the
deleted `workstations` namespace, and the fish `loginShellInit` that sourced
`/etc/workstation/{agent-env,otel-env}` — was removed on 2026-08-27. That module
still applies to every host via `sharedModules`, but now only seeds
`~/.claude.json` and sets the tool-permissions block.

One item survives the cull:

| What | Why it is still here | Why it is dead weight |
|------|---------------------|----------------------|
| `modules/programs/cli/codex/validate-bash.sh` | Shared Codex hook, and its other rules (force-push blocking) are live | Two of its rules only fire inside `/var/lib/claude-worker`, which no longer exists anywhere |

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

Comments that hit the target style — read one before writing your own. Anchored
to what they sit above, not to a line number, because line numbers rot:

- `modules/core/wifi.nix`, file header — why declarative WiFi exists, with the
  incident itself in the vault
- `modules/homelab/k3s/default.nix`, above the `eviction-hard`/`eviction-soft`
  kubelet args — why those thresholds and not the k3s defaults
- `modules/homelab/k3s/default.nix`, inside the `cfg.cni == "cilium"` server
  branch — `--disable-kube-proxy` is server-only and *fatals* on an agent
- `modules/homelab/k3s/default.nix`, above `trustedInterfaces` — why the host
  firewall must not filter Cilium's datapath interfaces
- `lib/firewall.nix`, file header — why both backends are always emitted

**Comments inside a `''` string are out of scope for now — all of them.** They
are rendered shell (`cluster-watchdog.nix`, `flux.nix`, `k3s-db-snapshot.nix`,
`fish.nix` and more), so editing one moves the derivation and breaks
`just parity`. They get swept when those scripts move to real `.sh` files, as
`modules/homelab/nixos-rebuild-trigger/` did — that move is also what put the
scripts under shellcheck, which no `''` string gets.
The same reason there is no `nix fmt`: a formatter reindents `''` strings.

The ratio counts only lines that *start* with `#`. Trailing comments are
invisible to it, so `foo # restates foo` is a violation the number will never
flag — judge those by reading.

`just bench` records the comment ratio in `metrics/history.jsonl`, measured over
nix-code lines (the body of `''` strings is excluded from both sides of the
fraction, so moving an inline script out to a real file neither helps nor hurts
the number). The target band is 7–13%; above that, the file is narrating itself.

`just lint-comments` is the enforced floor under that band, not the band itself:
it fails any `.nix` file of 30+ nix-code lines above **25%**, plus the
never-allowed shapes above, across `.nix` and `.sh` alike. The gap between 13%
and 25% is judgement; the ratchet only catches the indefensible. Tighten
`MAX_PERCENT` in `scripts/nix-comment-lint.sh` when the tree can take it.

## Conventions

- **Namespace boundary**: `homelab.*` is a cluster/platform capability a host
  opts into (k3s, flux, dns, acme, ntfy, tailscale, the rebuild trigger);
  `sam.*` is host identity and personal-machine concern (profile, desktop,
  wifi, thermal, hostSecrets). When both scopes need the same noun, the leaf
  states its scope — `homelab.secrets` (cluster) vs `sam.hostSecrets` (machine)
  — because an option path is usually read without its module.
- **No specialArgs**: Host data flows through `sam.profile` typed options, not `specialArgs` pass-through.
- **Desktop is per-host, not a role**: lenovo imports `modules/specialisations/desktop.nix` in its default boot, acer-swift does not. Gate GUI config on `sam.desktop.enable`.
- **User identity**: `lib/users.nix` holds git config and SSH keys, referenced as `sam.userConfig`.
- **Firewall**: LAN CIDR defaults to `192.168.10.0/24` (override via `sam.profile.lanCidr`). SSH is key-only, no root login.
- **Unfree is opt-in**: `nixpkgs.config.allowUnfree` is `false`. Adding an unfree package means adding its name to `allowUnfreePredicate` in `core/system.nix` (currently claude-code, obsidian, unrar, vscode) — otherwise eval fails and names it. Redistributable firmware is unaffected (separate nixpkgs knob).
- **Workers are not trusted-users**: `modules/roles/homelab-agent.nix` forces `nix.settings.trusted-users = [ "root" ]`. Deploys are push-from-lenovo; lenovo itself keeps `root` + `lukas` from `core/users.nix`.
- **stateVersion**: Set to `25.11` in `core/system.nix`.

## Adding a New Host

1. Create `hosts/<name>/` with `variables.nix`, `configuration.nix`, `hardware-configuration.nix` (Home Manager is shared — no per-host `home.nix`)
2. Create `flake-modules/hosts/<name>.nix` declaring `configurations.nixos.<name>` (reads variables, sets system/username/roles)
3. The module registry auto-discovers the rest

See `~/knowledge/homelab/runbooks/add-new-host.md` for detailed instructions.

## Further Documentation

Additional documentation is maintained in the knowledge (~/knowledge):

Paths are relative to `~/knowledge`, and every one below was verified to
exist. The vault uses relative markdown links, not `[[wikilinks]]`.

**Concepts:**
- `nix/nixos-modules.md` — NixOS declarative configuration
- `nix/nix-specialisations.md` — boot-time system variants
- `nix/k3s-nixos.md` — lightweight Kubernetes on NixOS
- `nix/sops-nixos.md` — secrets management with SOPS
- `nix/age-encryption.md` — modern encryption with age
- `homelab/concepts/flux-gitops.md` — GitOps continuous deployment

**Runbooks:**
- `homelab/runbooks/bootstrap-homelab.md` — complete cluster bootstrap guide
- `homelab/runbooks/add-new-host.md` — adding new NixOS hosts
- `homelab/runbooks/lenovo-death-recovery.md` — the control plane is gone

**Architecture and decisions:**
- `homelab/architecture/homelab-platform-overview.md` — platform architecture
- `homelab/decisions/` — ADRs, including ADR-024 (rebuild trigger) and
  ADR-025 (kernel choice), both referenced from code in this repo
