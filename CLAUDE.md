# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A NixOS + Home Manager configuration repository using **flake-parts** with a dendritic auto-discovery pattern. Manages Linux servers and laptops from a single flake.

## Build & Deploy Commands

```bash
# ── Verification: devenv tasks (devenv.nix), also run by the git hooks ──
devenv tasks run nixos:qa     # everything below, in order (= just check)
devenv tasks run nixos:lint-comments   # Comment Policy (density + forbidden shapes)
devenv tasks run nixos:lint-shell      # shellcheck scripts/*.sh
devenv tasks run nixos:secrets-verify  # wifi credentials sanity (skips without an age key)
devenv tasks run nixos:nvim-check      # lenovo's nvim starts headless clean
devenv tasks run nixos:flake-check     # nix flake check --all-systems
devenv tasks run nixos:verify          # build every x86 host, evaluate black-pi
devenv tasks run nixos:claude-settings-test  # generated Claude settings: default mode, bypass on request
# Hooks (installed by entering the devenv; .envrc does it on cd):
#   pre-commit: lint-comments + lint-shell; commit-msg: Why-gate;
#   pre-push:   no-force guard + nixos:qa on the PUSHED commit in a temp worktree.

# Or manually verify specific host:
nix build .#nixosConfigurations.<hostname>.config.system.build.toplevel --no-link

# ── Deployment (switch is plain nixos-rebuild; build/diff use nh) ──
just switch [HOST]            # Build and activate
just build  [HOST]            # Build only
just diff   [HOST]            # Build and print the package diff vs the running system

# Push from lenovo with deploy-rs (magic-rollback; logs in as `deploy`, no password)
just deploy-acer              # builds on lenovo
just deploy-pi                # builds on the Pi (remoteBuild); run inside zellij, it takes hours on a cache miss
just deploy-lenovo            # loopback self-push, proves the deploy-rs path
just deploy-msi               # only in its Mon-Fri ~09:00-21:00 power window
just deploy-naked-pi          # Pi 3 rf-lab; builds on the Pi, cache hits only

# Remote deploy via SSH (a host without a deploy-rs node yet)
nixos-rebuild switch --flake .#<hostname> --target-host lukas@<ip> --sudo --ask-sudo-password
```

Current hostnames: `acer-swift`, `lenovo-21CB001PMX` (flake attribute `lenovo`), `msi-ms7758`,
`black-pi` (aarch64; evaluated but not built on x86 hosts, build it on the Pi),
and `naked-pi` (Pi 3 `rf-lab` node, off k3s; `just deploy-naked-pi`;
runbook `~/knowledge/homelab/runbooks/naked-pi-rf-lab.md`).
`HOST` is the **flake attribute**, which for lenovo is not its hostname — the
`host` variable at the top of the Justfile does that mapping, so the argument is
only needed when targeting the other machine.

## Architecture

Flake-parts with dendritic auto-discovery: `flake-modules/` numbered for load
order; `modules/roles|home/*` auto-register; hosts are 2-3 files under
`hosts/<name>/` wired by `flake-modules/hosts/<name>.nix`; all host metadata
flows through the strict `sam.profile` submodule (unknown fields are build
errors) and GUI-ness keys off `sam.desktop.enable` alone. Full detail:
`docs/architecture.md` (profile field table, registry, desktop
specialisations, module layout).

### Secrets

SOPS-nix with age-based encryption. Config in `secrets/.sops.yaml`. Secrets decrypt at boot to `/run/secrets/`.

Two SOPS modules:
- **`modules/homelab/sops.nix`** (`homelab.secrets.enable`) — k3s cluster tokens, Flux deploy keys, Cloudflare API token. Encrypted to all host keys + Flux age key.
- **`modules/core/sops.nix`** (`sam.hostSecrets.enable`) — per-machine operator credentials on every physical host (Claude Code OAuth token, nix access token). Uses `mkDefault` for age config to avoid conflicts with the homelab module.

Secret scopes in `secrets/.sops.yaml`:

| Path pattern | Recipients | Purpose |
|--------------|-----------|---------|
| `homelab/nix-signing-key.yaml` | Personal + lenovo | deploy-rs closure-signing private key (workers trust the public half) |
| `homelab/*.yaml` | Personal + every cluster host + Flux | k3s, Cloudflare, Tailscale authkey, wifi, GitHub access token |
| `claude/llm-cloud.yaml` | Personal | factum `dev/cloud-env.sh` cloud keys, incl. its llm-gateway project key. Pi holds no provider key (llm-gateway), see `docs/pi.md` |
| `claude/*.yaml` | Personal + lenovo, acer-swift, black-pi | Claude Code OAuth token; Pi's llm-gateway project key (`llm-gateway.yaml`) |
| `cosign.key` | Personal + lenovo, acer-swift | Image-signing key used by `just sign` |

The `CLAUDE_CODE_OAUTH_TOKEN` is decrypted to `/run/secrets/claude_oauth_token` and exported in fish shell init via `modules/programs/cli/claude-code/mcp.nix`.

### Claude Code

Configuration lives in `modules/programs/cli/claude-code/`:

| File | Scope | Purpose |
|------|-------|---------|
| `mcp.nix` | All `devTools` hosts (shared HM module) | Settings, plugins, MCP servers, shebang fixes, SOPS token sourcing |
| `default.nix` | All `devTools` hosts (shared HM module) | Tool-permissions block, `programs.fish.enable` |
| `skills.nix` | All `devTools` hosts (shared HM module) | Symlinks skills and agents from the `skills` flake input |

**Plugin configuration** (`mcp.nix`): Declares `enabledPlugins` (superpowers, rust-analyzer-lsp, frontend-design, ralph-loop) and MCP servers (playwright/chromium) in `programs.claude-code.settings`.

**Personal skills and agents** are managed via the [`sammasak/skills`](https://github.com/sammasak/skills) repo, added as a non-flake input (`flake = false`). The `skills.nix` module auto-discovers all directories in `skills/` and `.md` files in `agents/` from that input and creates Home Manager symlinks:

- `skills/<name>/SKILL.md` → `~/.claude/skills/<name>/SKILL.md`
- `agents/<name>.md` → `~/.claude/agents/<name>.md`

These are available across all projects without manual `/plugin install`.

**Update workflow**:
```bash
# In ~/claude-code-skills: add/edit skills or agents, push to GitHub
# In ~/nixos-config:
nix flake update skills
sudo nixos-rebuild switch --flake .#<hostname>
```

### Codex

Configuration lives in `modules/programs/cli/codex/`:

| File | Scope | Purpose |
|------|-------|---------|
| `default.nix` | All `devTools` hosts (shared HM module) | Codex config, hooks, shared skill links, activation-time skill sync |
| `context-hook.sh` | All `devTools` hosts | Injects workspace routing hints for `~/knowledge`, workflows, and `skills` |
| `validate-bash.sh` | All `devTools` hosts | Blocks force pushes and other unsafe bash patterns |
| `sync-codex-skills.sh` | All `devTools` hosts | Regenerates Codex-local workflow skill wrappers after each activation |
| `workspace-routing/` | All `devTools` hosts | Base Codex skill for ICM workspace routing |

**Skill delivery model**:
- `~/.agents/skills/` holds the shared portable subset from the `skills` flake input
- `~/.codex/skills/` mirrors that portable subset for compatibility
- `sync-codex-skills.sh` then overlays Codex-local wrappers for canonical workspace workflows from `~/knowledge/workflows/*/CONTEXT.md`

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

nixpkgs (unstable), flake-parts, home-manager, stylix, sops-nix, skills — all following nixpkgs (except skills which is a plain source input).

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
