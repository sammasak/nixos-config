# Pre-Baked SvelteKit Template — Design Document

> **Status:** Implemented (2026-03-14)
> **Goal:** Eliminate cold-build wait by shipping a running SvelteKit dev server in the VM golden image.

## Problem

Previous architecture: Claude agents started from a blank workspace, ran `flake.nix` init, `npm install`, and cold-built a dev server. This meant 8–10 minutes before the user saw any preview.

User experience impact: Maya Chen (2/10 tech comfort, anxious after 30s silence) would abandon after the first confusing moment. A 9-minute black preview window was a critical failure point.

## Solution: Pre-Baked Template

The VM golden image ships with:
1. A SvelteKit 2 template project baked into the Nix store (`modules/homelab/claude-worker-template/`)
2. A `template-dev` systemd service that starts automatically on boot
3. Node.js 22, PostgreSQL 16, and Rust toolchain pre-installed as system packages

On first boot:
- `template-dev` service copies template files from Nix store to `~/workspace/`
- Runs `npm install` to install dependencies
- Starts `vite dev` on port 8080

The preview iframe on doable.sammasak.dev connects to port 8080 and shows the loader animation immediately after the VM reaches Running state (~30s after provisioning).

## Architecture

### Golden Image Components (`workstation-image.nix`)
- `nodejs_22` — Node.js runtime + npm
- `postgresql_16` — PostgreSQL server
- `rustup`, `cargo-watch` — Rust toolchain (optional use)
- PostgreSQL configured with `claude` database + user, trust auth on localhost

### Template Project (`claude-worker-template/`)
- SvelteKit 2 with TypeScript, Tailwind v4
- Port 8080, host 0.0.0.0 (matches preview iframe connection)
- Initial state: pure loader animation ("Claude is building your app…")
- Health endpoint: `GET /api/health` → `{ ok: true }`
- `package-lock.json` committed so `npm install` is reproducible

### Template Dev Service (`claude-worker.nix`)
```
systemd.services.template-dev:
  after: network.target, postgresql.service, claude-worker.service
  ExecStartPre[0]: copy template from Nix store → ~/workspace/ (if no package.json)
  ExecStartPre[1]: chmod -R u+w ~/workspace/ (Nix store is read-only)
  ExecStartPre[2]: npm install (if no node_modules/)
  ExecStartPre[3]: psql apply schema.sql (if present)
  ExecStart: node ~/workspace/node_modules/.bin/vite dev --port 8080 --host 0.0.0.0
  User: lukas (claude-worker user)
  Restart: on-failure
```

### Agent Instructions (`CLAUDE.md` in bootstrap secret)
Claude agents are told:
- The dev server is already running — do NOT start a new one
- Modify `~/workspace/` files; Vite HMR auto-reloads
- PostgreSQL ready at `postgresql://claude@localhost/claude`
- Create `~/workspace/schema.sql` for DB schema — auto-applies on restart
- Use `template-stack` Claude Code skill for detailed patterns

### Template Stack Skill (`template-stack/SKILL.md`)
Documents exact patterns for:
- UI pages (`src/routes/+page.svelte`)
- API endpoints (`src/routes/api/<name>/+server.ts` with pg.Pool)
- PostgreSQL schema (`schema.sql` migration pattern)
- Optional Rust backend with cargo-watch
- Production buildah deployment

## Startup Sequence

```
VM boots (t=0)
├── postgresql.service starts
├── claude-worker.service starts
└── template-dev.service starts
    ├── ExecStartPre: cp template → ~/workspace/ + chmod + npm install (~60s first boot)
    └── ExecStart: vite dev --port 8080 --host 0.0.0.0

doable frontend (t≈30s): VM reaches Running status
├── Preview iframe connects to ws.<name>.sammasak.dev:8080
├── NGINX proxy forwards to VM port 8080
└── User sees loader animation immediately

Claude agent receives goal (t≈35s, after controller posts spec.goal)
└── Modifies ~/workspace/ files → Vite HMR updates preview in real time
```

## Key Files

| File | Purpose |
|------|---------|
| `modules/homelab/workstation-image.nix` | System packages (Node, Postgres, Rust) |
| `modules/homelab/claude-worker.nix` | `template-dev` systemd service |
| `modules/homelab/claude-worker-template/` | SvelteKit template source (baked into image) |
| `~/homelab-gitops/.../claude-worker-bootstrap.secret.yaml` | CLAUDE.md with template environment docs |
| `~/claude-code-skills/skills/template-stack/SKILL.md` | Agent patterns for this environment |

## Trade-offs

| Concern | Decision |
|---------|----------|
| npm install at runtime vs pre-built | Runtime — keeps image size manageable; lockfile ensures reproducibility |
| Always-on Axum vs optional Rust | Optional — SvelteKit server routes handle most cases; Rust for perf-critical |
| SvelteKit scaffold vs pure loader | Pure loader — Claude transforms it to match the goal; no confusing generic UI |
| Goal text in loader vs generic | Generic — "Claude is building your app…" — goal text could be long/awkward |
| PostgreSQL as system service vs Docker | System service — simpler, no compose, matches NixOS module pattern |

## Open Issues

1. **npm install cold time (~60s)**: First boot takes ~60s for npm install. Consider pre-installing `node_modules` in the image (increases image size by ~80MB but eliminates wait).
2. **Rust recompile latency**: If agent uses Rust, first `cargo build` takes 5–10 min. Consider pre-seeding Cargo cache in the image.
3. **Preview proxy nginx**: Confirm NGINX on the VM proxies `:8080` — the preview iframe URL format needs validation.
4. **template-dev restart race**: If PostgreSQL starts slowly, `template-dev` may fail. The `after = postgresql.service` should handle this but needs testing.
