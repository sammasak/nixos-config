---
name: workspace-routing
description: Use when working inside ~/workspace or when a task refers to the ICM workspace, knowledge graph, rooms, or projects routed from workspace/CLAUDE.md. Guides Codex to load the right CLAUDE.md and CONTEXT.md files before acting.
---

# Workspace Routing

`~/workspace` is the root of your ICM knowledge graph.

## Workflow

1. Start with `~/workspace/CLAUDE.md`.
2. If the current working directory is inside `~/workspace`, read the nearest parent `CONTEXT.md`.
3. If a directory has no `CONTEXT.md`, use its `INDEX.md` only as a fallback signpost.
4. When the task mentions a known workspace project while you are outside `~/workspace`, use `CLAUDE.md` to route to the right room, then read that room's `CONTEXT.md`.

## Rules

- Treat `CLAUDE.md` as the workspace router.
- Treat `CONTEXT.md` as the room payload.
- Do not assume the legacy `~/knowledge-vault` layout; the active graph is `~/workspace`.
- If multiple rooms could apply, prefer the room closest to the current directory.
- Session records and ADRs live in the workspace repo; if you need to document work, route there instead of creating ad hoc notes elsewhere.
