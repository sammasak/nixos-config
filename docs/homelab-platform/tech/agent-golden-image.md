# Coding Agent Golden Image (KubeVirt)

> **Status:** Design — February 2026
>
> Defines the NixOS golden image for autonomous coding agent VMs running in the k3s/KubeVirt cluster, along with the plugin/skill repository pattern for declarative prompt and tooling management.

---

## Context

Project Jarvis (see [homelab-gitops design docs](https://github.com/sammasak/homelab-gitops/tree/main/docs/plans)) is an LLM-powered orchestrator that decomposes tasks into subtasks and dispatches them into isolated coding agent VMs. Each VM needs:

- Claude Code pre-installed and configured for headless operation
- A reproducible set of skills, prompts, and MCP server configs
- Runtime secret injection (API keys, SSH keys, task metadata)
- Fast boot from an immutable containerDisk image

The existing `workstation-template` host already provides most of this infrastructure. This document describes how to extend it (or fork it) for dedicated agent use.

---

## Current State

### Image Build Pipeline

```
hosts/workstation-template/
  variables.nix           roles = ["base"], headless, no desktop
  configuration.nix       imports workstation-image.nix
  home.nix                imports claude-code, git, cli-tools, direnv

modules/homelab/workstation-image.nix
  cloud-init, qemu-guest, disabled desktop services,
  disabled sleep/suspend, dev packages (git, tmux, jq, ripgrep, fd, kubectl)

Justfile
  just build              nixos-generators -> qcow2
  just publish            OCI containerDisk -> Harbor (skopeo)
  just release            build + publish
```

Published to: `registry.sammasak.dev/workstations/nixos-workstation:<tag>`

### KubeVirt Consumption (homelab-gitops)

WorkspaceClaim CRD (`workstations.sammasak.dev/v1alpha1`) declares intent:

```yaml
apiVersion: workstations.sammasak.dev/v1alpha1
kind: WorkspaceClaim
metadata:
  name: rocket
spec:
  containerDiskImage: "registry.sammasak.dev/workstations/nixos-workstation:latest"
  bootstrapSecretName: "rocket-bootstrap"
  runStrategy: Always
  instancetypeName: workstation-standard    # 2 vCPU, 4Gi
  loadBalancerIP: "192.168.10.208"
  workspaceStorage:
    size: 100Gi
```

The `workspace-controller` reconciles each claim into: VirtualMachine + PVC (`/workspace`) + Service (SSH LoadBalancer).

### Claude Code Module

`modules/programs/cli/claude-code/default.nix` already provides:

- `~/.claude/settings.json` with full tool permissions (Read, Write, Edit, Bash, Glob, Grep, WebFetch, WebSearch)
- `~/Justfile` with `just agent "prompt"` (foreground), `just agent-bg "prompt"` (tmux background), `just agent-stop`, `just agent-status`
- Login profile sourcing `/etc/workstation/agent-env` and `/etc/workstation/otel-env`
- Systemd user service `agent-heartbeat` that annotates the WorkspaceClaim to prevent idle auto-halt

---

## Claude Code Configuration Model

### File Locations

**Global (user-level):**

| Path | Purpose |
|------|---------|
| `~/.claude/settings.json` | Permissions (allow/deny/ask tool rules) |
| `~/.claude/CLAUDE.md` | Global instructions for all projects |
| `~/.claude/skills/` | Global skills (directories with `SKILL.md` entrypoints) |
| `~/.claude/commands/` | Global slash commands (`*.md` files) |
| `~/.claude/.credentials.json` | API credentials (Linux) |

**Project-level (in working directory):**

| Path | Purpose |
|------|---------|
| `./CLAUDE.md` | Project-specific instructions (checked into VCS) |
| `./.mcp.json` | Project MCP server configuration (checked into VCS) |
| `./.claude/settings.json` | Project settings (shared) |
| `./.claude/skills/` | Project-specific skills |
| `./.claude/commands/` | Project-specific slash commands |

### Authentication

Agent VMs use `ANTHROPIC_API_KEY` environment variable, sourced from `/etc/workstation/agent-env` (injected at runtime via cloud-init, never baked into the image).

### MCP Server Configuration

`.mcp.json` format (project-scoped, version-controlled):

```json
{
  "mcpServers": {
    "my-server": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@my/mcp-server"],
      "env": { "API_KEY": "..." }
    }
  }
}
```

Three scopes: project (`.mcp.json`), user (`~/.claude.json`), local (`~/.claude/settings.local.json`).

### Headless Operation

```bash
claude -p "fix the bug in main.py" --output-format json
```

Key flags for agent VMs:

- `--output-format json` — structured output for programmatic consumption
- `--allowedTools "Bash,Read,Write,Edit"` — restrict tools (optional, settings.json already configures this)
- `--max-turns N` — limit iterations for resource control
- `--dangerously-skip-permissions` — skip all permission prompts (only in isolated VMs)
- `--add-dir /path` — add additional working directories

---

## Proposed Architecture

### Image Strategy

**Recommendation:** Start with the existing `workstation-template` as-is for agent use. Split to a separate `agent-template` once the workflow is proven and image size/boot time matters.

| Image | Purpose | Persona | Lifecycle |
|-------|---------|---------|-----------|
| `workstation-template` | Interactive + agent (current) | Human or Jarvis SSHes in | Long-lived or ephemeral |
| `agent-template` (future) | Dedicated agent execution | Jarvis only, `claude -p` | Ephemeral per-task |

If/when splitting, the agent image would be leaner:

- No nushell, starship, or interactive shell niceties
- `documentation.enable = false`, `environment.noXlibs = true`
- Bash as default shell
- Richer Claude Code configuration (pre-baked skills, MCP configs)

### Agent Host Structure (future `agent-template`)

```
hosts/agent-template/
  variables.nix           username = "agent", roles = ["base"]
  configuration.nix       imports workstation-image.nix + agent-image.nix
  home.nix                claude-code + agent-skills module
```

### Secret Injection

Secrets flow at deploy time, never baked into images:

```
Kubernetes Secret (SOPS-encrypted in homelab-gitops)
  → Flux decrypts at reconcile
  → cloud-init Secret mounted as cloudInitNoCloud volume
  → cloud-init writes to /etc/workstation/agent-env
  → Bash login profile sources agent-env
  → ANTHROPIC_API_KEY available in agent's environment
```

Enhanced cloud-init userdata for agent VMs:

```yaml
#cloud-config
hostname: agent-task-42
users:
  - name: lukas
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ssh-ed25519 AAAA... jarvis-orchestrator

write_files:
  - path: /etc/workstation/agent-env
    permissions: '0600'
    owner: lukas:users
    content: |
      ANTHROPIC_API_KEY=sk-ant-api03-...
      OTEL_EXPORTER_OTLP_ENDPOINT=http://workstation-otel-collector.workstations.svc.cluster.local:4317
      OTEL_SERVICE_NAME=agent-task-42

runcmd:
  - chown -R lukas:users /workspace
```

The same golden image supports different API keys, task IDs, and agent identities — all controlled via the WorkspaceClaim's bootstrap secret.

---

## Plugin/Skill Repository

### Design Goals

1. Separate git repo with versioned Claude Code skills, prompts, CLAUDE.md, and MCP configs
2. Injectable at build time (baked into image) or runtime (cloned at boot)
3. Independent versioning — update skills without rebuilding the base image
4. Declarative management — skills are defined as code

### Repository Structure

```
agent-skills/
  CLAUDE.md                       # Global agent instructions
  .mcp.json                       # MCP server configurations
  skills/
    code-review/
      SKILL.md
    test-driven-development/
      SKILL.md
    systematic-debugging/
      SKILL.md
    nix-module-development/
      SKILL.md
    git-workflow/
      SKILL.md
  commands/
    deploy.md                     # /deploy slash command
    review-pr.md                  # /review-pr slash command
  prompts/
    system-prompt-coder.md        # System prompt template for coding agents
    system-prompt-reviewer.md     # System prompt template for review agents
```

### Injection Strategies

#### Strategy A: Bake into NixOS image (build-time)

Home Manager module fetches the skill repo at build time:

```nix
# modules/programs/cli/agent-skills/default.nix
{ pkgs, ... }:
let
  skillsRepo = pkgs.fetchFromGitHub {
    owner = "sammasak";
    repo = "agent-skills";
    rev = "v1.0.0";
    sha256 = "sha256-...";
  };
in
{
  home.file.".claude/CLAUDE.md".source = "${skillsRepo}/CLAUDE.md";

  home.file.".claude/skills" = {
    source = "${skillsRepo}/skills";
    recursive = true;
  };

  home.file.".claude/commands" = {
    source = "${skillsRepo}/commands";
    recursive = true;
  };
}
```

**Pros:** Fully reproducible, versioned, immutable (Nix hash guarantees exact content).
**Cons:** Requires image rebuild to update skills.

#### Strategy B: Clone at boot via cloud-init (runtime)

```yaml
runcmd:
  - |
    su - lukas -c '
      git clone --depth 1 --branch v1.2.0 \
        https://github.com/sammasak/agent-skills.git /tmp/agent-skills && \
      cp -r /tmp/agent-skills/skills/* ~/.claude/skills/ && \
      cp -r /tmp/agent-skills/commands/* ~/.claude/commands/ && \
      cp /tmp/agent-skills/CLAUDE.md ~/.claude/CLAUDE.md && \
      rm -rf /tmp/agent-skills || \
      echo "Skills overlay failed, using baked-in version"
    '
```

**Pros:** Update skills without rebuilding the image. Pin to tags or branches.
**Cons:** Adds boot time. Requires network access. Less reproducible.

#### Strategy C: Kubernetes ConfigMap mount (runtime)

**Pros:** Kubernetes-native, GitOps-managed.
**Cons:** 1MB size limit. Requires CRD/controller changes. virtio-fs or 9p complexity.

### Recommended: Hybrid (A + B)

- **Strategy A** as baseline: bake a known-good version via `fetchFromGitHub` pinned to a release tag
- **Strategy B** as overlay: cloud-init clones a newer version over the baked-in one, falling back gracefully if network fails
- Cloud-init snippet is parameterized in the bootstrap secret, so different tasks can use different skill versions

---

## KubeVirt Integration

### containerDisk (preferred for agents)

containerDisk is the clear choice for agent VMs:

- Ephemeral by design — run a task, destroy the VM
- Cached by container runtime on worker nodes — near-instant subsequent starts
- No 15-minute CDI import wait
- Root disk mutations discarded on restart — aligns with immutable agent model

### Agent VM Lifecycle

```
Jarvis ExecuteNode
  │
  ├─ 1. Create WorkspaceClaim (agent-task-42)
  │     containerDiskImage: nixos-workstation:latest
  │     bootstrapSecretName: agent-task-42-bootstrap
  │     runStrategy: Always
  │     instancetypeName: workstation-standard
  │     idleHaltAfterMinutes: 60
  │     labels: { purpose: agent, task-id: task-42, jarvis-managed: true }
  │
  ├─ 2. workspace-controller reconciles → VM + PVC + Service
  │
  ├─ 3. VM boots, cloud-init configures user/keys/env/skills
  │
  ├─ 4. Jarvis SSHes in:
  │     cd /workspace && git clone <repo>
  │     just agent "fix the bug in issue #123"
  │
  ├─ 5. Agent runs, heartbeat keeps VM alive
  │
  ├─ 6. Agent completes, Jarvis collects results via SSH
  │
  └─ 7. Jarvis deletes WorkspaceClaim → controller GCs VM + Service
```

### Instancetype Selection

| Instancetype | Spec | Agent Use Case |
|-------------|------|----------------|
| `workstation-standard` | 2 vCPU, 4Gi | Simple fixes, docs, single-file changes |
| `workstation-large` | 4 vCPU, 8Gi | Multi-file refactoring, test suites |
| `workstation-xlarge` | 8 vCPU, 16Gi | Large codebase analysis, compilation |

Claude Code's primary resource consumption is network I/O (API calls) and disk I/O (file ops). CPU/memory are consumed mainly by language servers, build tools, and MCP server processes. 4Gi is sufficient for most agent tasks; 8Gi is safer when builds or tests are involved.

---

## Open Questions and Trade-offs

### Agent User Identity

- **Same user (`lukas`):** Simpler, reuses existing cloud-init and SSH keys. Start here.
- **Dedicated user (`agent`):** Cleaner audit trail, distinct git identity. Move to this once agent workflow is proven.
- Interim: set a distinct git author via cloud-init or CLAUDE.md instruction so agent commits are identifiable.

### Workspace PVC Lifecycle

- Agent VMs: use smaller persistent PVC (20Gi vs 100Gi) with auto-cleanup after task completion
- Jarvis should extract results via SSH before deleting the WorkspaceClaim
- PVC can optionally be retained for post-mortem analysis

### Skills Versioning

- Skills change weekly → Strategy B (cloud-init clone)
- Skills change monthly → Strategy A (bake into image)
- Different tasks need different skills → Strategy B with parameterized tag in cloud-init
- **Start with Strategy A** since there are no skills yet; add cloud-init overlay once iteration speed matters

### MCP Server Overhead

Each MCP server is a separate process that starts/stops per `claude -p` invocation. Keep MCP servers minimal — Claude Code's built-in tools (Read, Write, Edit, Bash, Glob, Grep) cover most coding tasks without external servers.

### Resource Constraints

Each agent VM uses minimum 2 vCPU + 4Gi. With limited cluster capacity:

- Use heartbeat + idle halt aggressively (short TTLs, e.g. 30 minutes)
- Have Jarvis check cluster capacity before spawning VMs
- Use `workstation-standard` by default, escalate only for compilation tasks

### Security

- API keys injected at runtime, never baked into images
- Git SSH keys: use deploy keys scoped to specific repos, not personal SSH key
- VM itself is the security boundary — wide-open permissions inside are acceptable
- Consider network egress policies in a future hardening phase

---

## Implementation Path

1. **Create the skill/prompt repository** — separate git repo with CLAUDE.md, skills, commands
2. **Create a NixOS Home Manager module** (`modules/programs/cli/agent-skills/`) that bakes the skill repo into `~/.claude/skills/` and `~/.claude/commands/`
3. **Extend cloud-init userdata** for agent-specific config (task ID, skill overlay, auto-cleanup)
4. **Reuse `workstation-template`** initially — it is functionally ready for agent use today
5. **Optionally split to `agent-template`** once workflow is proven and image size matters
6. **Extend Justfile** with `build-agent` / `publish-agent` / `release-agent` targets

---

## Related

- `hosts/workstation-template/` — current workstation image config
- `modules/homelab/workstation-image.nix` — workstation profile module
- `modules/programs/cli/claude-code/` — Claude Code Home Manager module
- `Justfile` — image build/publish recipes
- [homelab-gitops: workstation-fleet.md](https://github.com/sammasak/homelab-gitops/blob/main/docs/tech/workstation-fleet.md)
- [homelab-gitops: Project Jarvis design](https://github.com/sammasak/homelab-gitops/blob/main/docs/plans/2026-02-15-project-jarvis-design.md)
- [homelab-gitops: Jarvis interaction layer](https://github.com/sammasak/homelab-gitops/blob/main/docs/plans/2026-02-16-jarvis-interaction-layer-design.md)
- [homelab-gitops: WorkspaceClaim CRD](https://github.com/sammasak/homelab-gitops/blob/main/apps/workstations/api/workspaceclaims-crd.yaml)
