---
name: workspace-routing
description: Use when working inside ~/knowledge or when a task refers to the ICM knowledge graph, workflows, skills, rooms, or projects routed from ~/knowledge/CLAUDE.md. Guides Codex to load the right CLAUDE.md and CONTEXT.md files before acting.
---

# Workspace Routing

`~/knowledge` is the root of your ICM knowledge graph.

## Workflow

1. Start with `~/knowledge/CLAUDE.md`.
2. If the current working directory is inside `~/knowledge`, read the nearest parent `CONTEXT.md`.
3. If a directory has no `CONTEXT.md`, use its `INDEX.md` only as a fallback signpost.
4. When the task mentions a known project while you are outside `~/knowledge`, use `CLAUDE.md` to route to the right room, then read that room's `CONTEXT.md`.
5. When the task mentions a named workflow, read `~/knowledge/workflows/INDEX.md` for discovery and then the matching `~/knowledge/workflows/<name>/CONTEXT.md`.
6. When the task mentions `skills` or `claude-code-skills`, route through `~/knowledge/CLAUDE.md`, then read `~/knowledge/dev/claude-code-skills/CONTEXT.md`.

## Rules

- Treat `CLAUDE.md` as the workspace router.
- Treat `CONTEXT.md` as the room payload.
- Do not assume the legacy `~/knowledge-vault` layout; the active graph is `~/knowledge`.
- Use the `workflows/` room for named multi-step procedures.
- If multiple rooms could apply, prefer the room closest to the current directory.
- Session records and ADRs live in the knowledge repo; if you need to document work, route there instead of creating ad hoc notes elsewhere.
