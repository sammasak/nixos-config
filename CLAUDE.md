# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A NixOS + Home Manager configuration repository using **flake-parts**. Manages Linux servers and laptops from a single flake.

## Build & Deploy Commands

```bash
# ── Verification: devenv tasks, also run by the git hooks. nixos:qa runs every gate; most
#    gates also have their own nixos:* task, listed with descriptions in devenv.nix `tasks`. ──
devenv tasks run nixos:qa           # every gate in order (= just check): lints, secrets-verify, flake check, then the tests
devenv tasks run nixos:flake-check  # nix flake check --all-systems: builds every x86 host, evaluates the Pis (= just verify)
# Hooks: the shims in .githooks/ (core.hooksPath) run prek on the checkout's .pre-commit-config.yaml,
# which entering the devenv generates (.envrc does it on cd); without one, the main checkout's:
#   pre-commit: lint-comments + lint-shell; commit-msg: subject <= 72 chars, a body needs a `Why:` line;
#   pre-push:   no-force guard + nixos:qa on the PUSHED commit in a temp worktree
#               (lints only when everything changed since origin/main is docs/ or a top-level *.md,
#               unless a scripts/test-* file names one of the changed files).
# The tests read the hosts through one probe evaluation (scripts/gate-probe.nix), built once by nixos:qa.

# Or manually verify specific host:
nix build .#nixosConfigurations.<hostname>.config.system.build.toplevel --no-link

# QEMU proof (a package, not a check):
nix build -L .#packages.x86_64-linux.rf-hwsim-dataplane

# ── Deployment (switch is plain nixos-rebuild; build/diff use nh) ──
just switch [HOST]            # Build and activate
just build  [HOST]            # Build only
just diff   [HOST]            # Build and print the package diff vs the running system

# Push from lenovo with deploy-rs (magic rollback; logs in as `deploy`, no password).
# --skip-checks under a 7G, no-swap cap on the deploy-rs client. The pre-push gate runs the
# flake check on pushed non-docs commits; a dirty or unpushed tree deploys unchecked (it warns).
just deploy HOST              # HOST: a deploy-rs node, any other name is refused
#   then on the target: `systemctl is-system-running` = running, and `readlink /run/current-system`
#   = `dirname "$(readlink -f /nix/var/nix/profiles/system/init)"`
#   lenovo      loopback self-push, proves the deploy-rs path
#   acer-swift  builds on acer (remoteBuild)
#   msi-ms7758  builds on msi; only in its Mon-Fri ~09:00-21:00 power window
#   black-pi    builds on the Pi; run inside zellij, it takes hours on a cache miss
#   naked-pi    Pi 3 rf-lab; builds on the Pi, cache hits only
just dry-activate HOST        # Same build and copy, then the units a switch would stop/restart/reload/start
                              # and the closure diff vs the running system; activates nothing, but read
                              # the output: it exits 0 even when the dry activation fails
just role-vm-test [BREAK=1]   # QEMU boot of the runtime-host role (msi only); BREAK=1 must fail
```

Current hostnames: `acer-swift`, `lenovo-21CB001PMX` (flake attribute `lenovo`), `msi-ms7758`,
`black-pi` (aarch64; evaluated but not built on x86 hosts, build it on the Pi),
and `naked-pi` (Pi 3 `rf-lab` node, off k3s; `just deploy naked-pi`;
runbook `~/knowledge/homelab/runbooks/naked-pi-rf-lab.md`).
`HOST` is the **flake attribute**, which for lenovo is not its hostname — the
`host` variable at the top of the Justfile does that mapping, so the argument is
only needed when targeting the other machine.

## Architecture

`flake.nix` imports every file under `flake-modules/` (import-tree; the number
prefixes set no order); `modules/roles|home/*.nix` auto-register; hosts are 3 files under
`hosts/<name>/` wired by an entry (roles and deploy fields) in `flake-modules/hosts.nix`; all host metadata
flows through the strict `sam.profile` submodule (unknown fields are build
errors) and GUI-ness keys off `sam.desktop.enable` alone. Full detail:
`docs/architecture.md` (profile field table, registry, desktop
specialisations, module layout).

### Secrets

SOPS-nix with age-based encryption. Config in `secrets/.sops.yaml`. Secrets decrypt at activation (every switch and boot) to `/run/secrets/`.

Two SOPS modules:
- **`modules/homelab/sops.nix`** (`homelab.secrets.enable`): the host-key age identity and the k3s cluster token, on every k3s node. The Flux deploy and age keys, Cloudflare API token and Tailscale authkey are declared by `flux.nix`, `acme.nix` and `tailscale.nix`, so only the host that enables those (lenovo) decrypts them. The OTLP token is declared by `native-otel-relay.nix` on `nativeOtel` hosts.
- **`modules/core/sops.nix`** (`sam.hostSecrets.enable`): per-machine operator credentials (Claude Code OAuth token, Pi gateway key on `pi` hosts, nix access token) on lenovo, black-pi and the runtime-host role (acer-swift, msi-ms7758); not naked-pi. Uses `mkDefault` for age config to avoid conflicts with the homelab module.

Secret scopes in `secrets/.sops.yaml`:

| Path pattern | Recipients | Purpose |
|--------------|-----------|---------|
| `homelab/nix-signing-key.yaml` | Personal + lenovo | deploy-rs closure-signing private key (workers trust the public half) |
| `homelab/wifi.yaml` | as `homelab/*.yaml`, plus naked-pi | Home Wi-Fi PSK |
| `homelab/*.yaml` | Personal + every cluster host + Flux | k3s, Cloudflare, Tailscale authkey, GitHub access token |
| `claude/llm-cloud.yaml` | Personal | factum `dev/cloud-env.sh` cloud keys. Pi holds no provider key (llm-gateway), see `docs/pi.md` |
| `claude/oauth.yaml` | Personal + lenovo, acer-swift, msi-ms7758, black-pi | Claude OAuth token |
| `claude/native-otlp-auth.yaml` | Personal + lenovo, acer-swift, msi-ms7758 | OTLP auth |
| `claude/*.yaml` | Personal + lenovo, acer-swift, black-pi | Pi's gateway key |
| `cosign.key` | Personal + lenovo, acer-swift | Image-signing key used by `just sign` |

Every acer-swift recipient except `native-otlp-auth.yaml` also includes acer's own `lukas` user key.

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
- `agents/<name>.md` → `~/.claude/agents/<name>.md` (role adapters included: plain subagents whose prompt states the one allowed command form; Claude Code's permission prompt is the gate, see `docs/herdr.md` and the skills repo `docs/operator-runbook.md`)
- The coordinator adapter only on the coordinator host (the one with `sam.herdr.machines`, lenovo), which also declares Codex's `[agents.coordinator] config_file` in `~/.codex/config.toml` as the skills input's `agents/coordinator/codex.toml` (never a symlink under `~/.codex/agents`: Codex opens it with O_NOFOLLOW); rollout in `docs/rollout-coordinator.md`


**Update workflow**:
```bash
# In ~/claude-code-skills: add/edit skills or agents, push to GitHub
# In ~/nixos-config:
nix flake update skills
just switch
```

**Bulk reader** (`sam.claude.bulkReader`, off by default): registers the skills input's shunt hooks, a `Read`
PreToolUse entry (`shunt-check-read.sh`) and `shunt-check-bash-read.sh` appended to the `Bash` list after the
existing hooks. A whole-file read estimated over 8000 tokens (`minTokens`, null = the skills default; source code and
instruction files are never redirected) is redirected once to
`scripts/bulk-read.sh` (bulk-reader skill), which summarises it with headless `claude -p` on `model` (null =
haiku) under the session's own auth. `spillOutput` (default on with `enable`) adds a `Bash` PostToolUse entry
(`shunt-spill-output.sh`): a successful command output over 12000 chars is saved under `~/.cache/claude-spill/` and
the session gets the path with a head and tail excerpt; failed commands are untouched. With a skills pin that lacks the hooks it registers nothing.
- Host: `sam.claude.bulkReader.enable = true;` in `hosts/<host>/configuration.nix`.
- Environments: a guest does not inherit its host's value; the host adds a guest module, e.g. for one instance
  `services.devEnvironments.guestModules = [ ({ devEnvironment, ... }: { sam.claude.bulkReader.enable = devEnvironment.name == "canary"; }) ];`
- Rollback: set it false and switch, or `SHUNT_DISABLE=1` in the environment Claude starts from (no rebuild).
- Running sessions keep the hooks they started with: settings are read at session start, so restart a session to
  pick up a change. `notifyHookGeneration` pings ntfy only when the skills store path changes (a pin bump), not
  when this option flips.

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

See `flake.nix`. factum, nix-audit, alert-bridge and rf-proto are pinned by `?rev=` in their URL, so `nix flake update`
does not move them: edit the rev.

## Comment Policy

Nix is declarative: the option name and value already say *what*. A comment
earns its line only by saying something the code cannot. Write one only when it
is one of these five:

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
entries in a long flat list (`packages.nix`'s groups) is navigation, not restatement, and stays.

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
`just parity [BASE]` evaluates every host's toplevel drvPath and deploy-rs node
(as JSON, profile paths as drvPaths), plus `deploy` minus `nodes`, at BASE (default the merge base with
origin/main) and in the working tree (tracked files incl. uncommitted edits, not
untracked ones), one evaluation at a time. Hosts and nodes are the union of
`nixosConfigurations` and `deploy.nodes` names on both sides; one on one side only
is reported ADDED or REMOVED without being evaluated. It exits non-zero if anything
moved, was added or removed, or any evaluation failed; a host with no node on
either side is only reported.

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
- **Unfree is opt-in**: `nixpkgs.config.allowUnfree` is `false`. Adding an unfree package means adding its name to `allowUnfreePredicate` in `core/system.nix` (currently antigravity-cli, claude-code, unrar); otherwise eval fails and names it. Redistributable firmware is unaffected (separate nixpkgs knob).
- **Workers are not trusted-users**: `modules/roles/homelab-agent.nix` and `rf-lab.nix` force `nix.settings.trusted-users = [ "root" ]`. Deploys are push-from-lenovo; lenovo itself keeps `root` + `lukas` from `core/users.nix`.
- **stateVersion**: Set to `25.11` in `core/system.nix`.

## Adding a New Host

- `hosts/<dir>/` (variables + configuration + hardware scan);
- an entry with its roles in `flake-modules/hosts.nix` (`hostDir` and
  `deploy.hostname` default to the entry name; `deploy.remoteBuild` is
  required, true unless lenovo can build it);
  its deploy-rs node follows from the entry;
- the `just deploy` HOST pattern (checked by `scripts/test-ssh-known-hosts.py`);
- its pinned key in `modules/core/ssh-known-hosts.nix` and its sops recipient;
- optionally `sam.cliTools.*` (factum, nix-audit) in its `configuration.nix`.

`just parity` picks the host up on its own. Full procedure:
`~/knowledge/homelab/runbooks/add-new-host.md`.

## Further Documentation

The vault (`~/knowledge`) owns concepts, runbooks, and ADRs for everything
this repo touches — route via `~/knowledge/CLAUDE.md`; start at `nix/` for
NixOS concepts and `homelab/` for runbooks and decisions (ADR-024 rebuild
trigger and ADR-025 kernel choice are referenced from code here).
