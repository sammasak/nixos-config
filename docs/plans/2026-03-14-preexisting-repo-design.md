# Pre-existing Repo Support Design

**Date:** 2026-03-14
**Status:** Approved

## Problem

doable.sammasak.dev only supports building from a blank SvelteKit template. Users who want Claude to work on an existing GitHub repo (use case A: improve existing app; use case B: different tech stack) have no entry point.

## Approach

**Approach A — Claude handles everything via goal injection.**

No new VM boot-time infrastructure. The workspace controller prepends a clone+setup preamble to the goal when `spec.repo_url` is set. Claude clones the repo, creates `flake.nix` if missing, starts the dev server on `:8080`, then works on the goal. `template-dev` only starts Vite when the workspace actually looks like a Vite project.

## Data Flow

```
Landing "Import" tab
  → createWorkspace({ name, goal, repo_url })
  → workstation-api CreateWorkspaceRequest { repo_url }
  → WorkspaceClaim CRD spec.repo_url
  → workspace controller post_goal_if_needed()
      → if spec.repo_url set: prepend clone preamble to goal
  → claude-worker receives enriched goal
  → Claude clones, creates flake.nix, starts :8080, works on goal
```

## Components

### 1. Frontend (`/tmp/doable/src/routes/+page.svelte`)

New "Import repo" tab alongside "Build from scratch":
- GitHub repo URL field (validated as `https://github.com/...`)
- Project name (same rules as today)
- Goal textarea (required)
- Sends `repo_url` in `createWorkspace()` call

### 2. workstation-api (`~/workstation-api/`)

- `CreateWorkspaceRequest`: add `repo_url: Option<String>`
- `WorkspaceClaimSpec`: add `repo_url: Option<String>`
- Validation: basic URL format check (must start with `https://github.com/`)

### 3. Workspace controller (`post_goal_if_needed`)

When `spec.repo_url` is set, prepend to the posted goal:

```
Before starting, set up the workspace:
1. rm -rf ~/workspace/* ~/workspace/.[^.]*
2. git clone [repo_url] ~/workspace
3. If no flake.nix exists, create one for this stack
4. Start the dev server on :8080 in the background
Then: [user goal]
```

### 4. `template-dev` systemd service (`claude-worker.nix`)

Change `ExecStart` from unconditional Vite to conditional:

```bash
if [ -f workspace/package.json ] && grep -q '"vite"' workspace/package.json 2>/dev/null; then
  exec vite dev --port 8080 --host 0.0.0.0
else
  exec sleep infinity
fi
```

ExecStartPre[0] already skips template copy if `package.json` exists — no change needed there.

**Behaviour matrix:**

| Workspace state | ExecStartPre[0] | ExecStart |
|---|---|---|
| Empty (fresh VM, no repo) | Copy SvelteKit template | Start Vite |
| Cloned SvelteKit repo | Skip copy | Start Vite |
| Cloned non-JS repo (Python/Go/Rust) | Skip copy | sleep infinity (Claude starts its own) |

### 5. template-stack SKILL.md + bootstrap CLAUDE.md

Add a "Repo mode" section:

> If your workspace was cloned from a repo (not the default SvelteKit template):
> 1. Run `git log --oneline -5` to understand recent context
> 2. Check for `flake.nix` — if missing, create one for this stack
> 3. Start the dev server on `:8080` in the background via `nix develop`
> 4. Then work on the goal

## Scope Limits

- Public GitHub repos only (no auth, no SSH keys)
- No branch selection (default branch only)
- No workspace persistence across VM destroy/recreate (clone happens fresh each time)
- Live preview appears only after Claude starts the dev server (no instant loader for repo mode)

## Success Criteria

1. User can paste a public GitHub URL on the "Import" tab and submit a goal
2. Claude's first actions are: clear workspace → clone → flake.nix check → dev server
3. Live preview appears on `:8080` once Claude starts it
4. "Build from scratch" tab unchanged
