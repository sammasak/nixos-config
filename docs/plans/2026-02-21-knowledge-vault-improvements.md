# Knowledge Vault Improvements Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Move knowledge-vault to ~/knowledge-vault, remove Obsidian MCP dependency, create unified Claude skill for vault operations with auto-sync.

**Architecture:** Replace MCP-based vault operations with direct file operations (Read/Write/Edit) orchestrated by a unified Claude skill that leverages existing Justfile automation. All vault modifications auto-commit and push to keep hosts synchronized.

**Tech Stack:** NixOS, Home Manager, Claude Code skills, Justfile, Git

---

## Task 1: Update Obsidian Module Vault Path

**Files:**
- Modify: `nixos-config/modules/programs/gui/obsidian/default.nix`

**Step 1: Update vault target path**

Change line 16 from:
```nix
target = "Documents/knowledge-vault";
```
to:
```nix
target = "knowledge-vault";
```

**Step 2: Update all home.file paths (batch replace)**

Find and replace in the file:
- FROM: `"Documents/knowledge-vault/`
- TO: `"knowledge-vault/`

This affects lines 58-285 (all template and directory paths).

**Step 3: Verify changes**

Run: `git diff modules/programs/gui/obsidian/default.nix`

Expected output should show:
- Line 16: `target = "knowledge-vault";`
- All home.file paths updated from `Documents/knowledge-vault/` to `knowledge-vault/`
- No other changes

**Step 4: Test NixOS build**

Run: `nix build .#nixosConfigurations.acer-swift.config.system.build.toplevel --no-link`

Expected: Build succeeds with no errors

**Step 5: Commit**

```bash
git add modules/programs/gui/obsidian/default.nix
git commit -m "refactor: move vault from ~/Documents/knowledge-vault to ~/knowledge-vault"
```

---

## Task 2: Remove Obsidian MCP Server

**Files:**
- Modify: `nixos-config/modules/programs/cli/claude-code/mcp.nix`

**Step 1: Remove obsidian MCP server block**

Delete lines 35-44 (the entire obsidian MCP server configuration):
```nix
      # Obsidian filesystem MCP - works without Obsidian app running
      # Provides read/write access to vault
      obsidian = {
        command = "npx";
        args = [
          "-y"
          "@mauricio.wolff/mcp-obsidian@latest"
          "${config.home.homeDirectory}/Documents/knowledge-vault"
        ];
      };
```

**Step 2: Verify mcpServers structure**

After deletion, the `mcpServers` block should only contain:
```nix
mcpServers = {
  playwright = {
    command = "sh";
    args = [
      "-c"
      ''exec npx @playwright/mcp@latest --headless --browser chromium --executable-path "$(which chromium)"''
    ];
  };
};
```

**Step 3: Check for any other obsidian references**

Run: `grep -i "obsidian" modules/programs/cli/claude-code/mcp.nix`

Expected: Should only show comments if any, no active configuration

**Step 4: Test NixOS build**

Run: `nix build .#nixosConfigurations.acer-swift.config.system.build.toplevel --no-link`

Expected: Build succeeds with no errors

**Step 5: Commit**

```bash
git add modules/programs/cli/claude-code/mcp.nix
git commit -m "refactor: remove obsidian MCP server from claude-code config"
```

---

## Task 3: Add sync-push Command to Vault Justfile

**Files:**
- Modify: `~/Documents/knowledge-vault/Justfile`

**Step 1: Navigate to vault**

Run: `cd ~/Documents/knowledge-vault`

Expected: Current directory is vault

**Step 2: Add sync-push recipe**

Add this block after the `push` recipe (after line 95), before the `promote` recipe:

```just
# Sync vault and push changes with commit message (atomic operation)
sync-push message:
    @just sync
    git add .
    git commit -m "{{message}}"
    git push origin main
```

**Step 3: Verify Justfile syntax**

Run: `just --list`

Expected output should include:
- `sync` - existing recipe
- `sync-push message` - new recipe
- `push message` - existing recipe
- All other existing recipes

**Step 4: Test sync-push command (dry run)**

Create a test file:
```bash
echo "test" > /tmp/test-sync-push.txt
```

Run: `just sync-push "test: verify sync-push command"`

Expected:
1. Pulls latest changes from remote
2. Stages all changes (including test file if copied to vault)
3. Creates commit with message
4. Pushes to origin/main

**Step 5: Clean up test and commit**

```bash
git log -1  # Verify last commit
cd ~/nixos-config  # Return to nixos-config for next tasks
```

Note: This modifies the vault repo, not nixos-config, so no commit needed in nixos-config.

---

## Task 4: Create Unified Knowledge Vault Skill

**Files:**
- Create: `~/claude-code-skills/skills/knowledge-vault/SKILL.md`

**Step 1: Create skill directory**

Run: `mkdir -p ~/claude-code-skills/skills/knowledge-vault`

Expected: Directory created

**Step 2: Create SKILL.md with comprehensive content**

Create file: `~/claude-code-skills/skills/knowledge-vault/SKILL.md`

```markdown
---
name: knowledge-vault
description: Manage documentation in knowledge vault with auto-sync - create docs from templates, update content, manage projects, all changes auto-pushed to remote
---

# Knowledge Vault

Manage all documentation in the knowledge vault with automatic git synchronization.

## When to Use

- Creating new documentation (concepts, architecture, runbooks, plans, decisions)
- Updating existing documentation
- Managing project documentation and status
- Any operation that modifies vault content

## Prerequisites

**Vault Location:** `~/knowledge-vault`

**Required Tools:**
- `just` - Task runner (provides automation commands)
- `git` - Version control

**Vault Structure:**
```
~/knowledge-vault/
├── Infrastructure/   # NixOS, system config, deployment
├── Homelab/         # Kubernetes, GitOps, cluster ops
├── Development/     # Dev tools, workflows, AI agents
├── Drafts/          # Work in progress (not yet promoted)
├── Archive/         # Historical documentation
└── Meta/            # Templates and scripts
    ├── templates/   # Document templates
    └── scripts/     # Automation scripts
```

## Core Principles

**ALWAYS AUTO-SYNC:**
1. `just sync` before any operation (pull latest changes)
2. Perform vault operation (create/update document)
3. `just sync-push "message"` after changes (commit + push)

This keeps all hosts synchronized and prevents merge conflicts.

## Operations

### 1. Create New Document

**Workflow:**
```
1. Sync vault: just sync
2. Create draft: just draft <name> <template>
3. Write content with Write tool (include proper frontmatter)
4. Validate: just validate
5. Sync and push: just sync-push "docs: draft <name>"
```

**Available Templates:**
- `concept` - How something works, mental models
- `architecture` - System design, component relationships
- `runbook` - Step-by-step operational procedures
- `plan` - Implementation plans, project planning
- `decision` - ADRs, architectural decisions

**Template Structure:**

All documents must have YAML frontmatter:
```yaml
---
title: "Human Readable Title"
domain: infrastructure|homelab|development
type: concept|architecture|runbook|plan|decision
tags: [tag1, tag2]
created: YYYY-MM-DD
updated: YYYY-MM-DD
status: draft|published|archived
related: ["[[Related Doc]]"]
---
```

**Content Guidelines:**
- Start with `## Overview` section
- Use Mermaid diagrams for architecture/runbooks
- Link to related docs with `[[wikilinks]]`
- Include examples and code snippets
- Add `## References` section with external links

**Example:**
```
User: "Document the NixOS specialisation pattern"
**Step 3: Copy skill content to file**

The complete skill content has been prepared. Copy it:

Run: `cat > ~/claude-code-skills/skills/knowledge-vault/SKILL.md << 'SKILLEOF'
[Copy the complete content from /tmp/knowledge-vault-skill-content.md]
SKILLEOF`

Or simply: `cp /tmp/knowledge-vault-skill-content.md ~/claude-code-skills/skills/knowledge-vault/SKILL.md`

**Step 4: Verify skill file**

Run: `wc -l ~/claude-code-skills/skills/knowledge-vault/SKILL.md`

Expected: ~290 lines

Run: `head -20 ~/claude-code-skills/skills/knowledge-vault/SKILL.md`

Expected: Shows frontmatter with name: knowledge-vault

**Step 5: Commit skill**

```bash
cd ~/claude-code-skills
git add skills/knowledge-vault/
git commit -m "feat: add unified knowledge-vault skill

Replaces 4 separate skills with single comprehensive skill:
- Direct file operations instead of MCP
- Auto-sync pattern (sync before, push after)
- Integrates with Justfile automation
- Covers document creation, updates, project management"
```

---

## Task 5: Archive Old Vault Skills

**Files:**
- Move: `~/claude-code-skills/skills/document-to-vault/`
- Move: `~/claude-code-skills/skills/documentation-to-obsidian/`
- Move: `~/claude-code-skills/skills/manage-project-in-vault/`
- Move: `~/claude-code-skills/skills/vault-sync/`

**Step 1: Create archive directory**

Run: `mkdir -p ~/claude-code-skills/.archived/vault-skills`

**Step 2: Move old skills**

```bash
cd ~/claude-code-skills
mv skills/document-to-vault .archived/vault-skills/
mv skills/documentation-to-obsidian .archived/vault-skills/
mv skills/manage-project-in-vault .archived/vault-skills/
mv skills/vault-sync .archived/vault-skills/
```

**Step 3: Verify**

Run: `ls -la .archived/vault-skills/`

Expected: Shows 4 skill directories

**Step 4: Commit**

```bash
git add -A
git commit -m "refactor: archive old vault skills"
```

---

## Task 6: Move Vault

**Step 1: Verify current vault**

Run: `cd ~/Documents/knowledge-vault && git status`

**Step 2: Commit any pending changes**

If changes exist:
```bash
git add .
git commit -m "chore: commit before migration"
git push
```

**Step 3: Move vault**

Run: `mv ~/Documents/knowledge-vault ~/knowledge-vault`

**Step 4: Verify git works**

```bash
cd ~/knowledge-vault
git status
git remote -v
just --list
```

---

## Task 7: Apply NixOS Config

**Step 1: Build config**

Run: `cd ~/nixos-config && nix build .#nixosConfigurations.acer-swift.config.system.build.toplevel --no-link`

**Step 2: Apply**

Run: `sudo nixos-rebuild switch --flake .#acer-swift`

**Step 3: Verify**

Run: `ls -la ~/knowledge-vault/Meta/templates/`

Expected: Templates created at new location

---

## Task 8: Update Skills Flake Input

**Step 1: Push skills repo**

```bash
cd ~/claude-code-skills
git push origin main
```

**Step 2: Update flake**

```bash
cd ~/nixos-config
nix flake update claude-code-skills
```

**Step 3: Rebuild**

Run: `sudo nixos-rebuild switch --flake .#acer-swift`

**Step 4: Verify new skill**

Run: `ls -la ~/.claude/skills/knowledge-vault/SKILL.md`

**Step 5: Commit flake update**

```bash
git add flake.lock
git commit -m "chore: update claude-code-skills input"
```

---

## Task 9: Verification

**Step 1: Test workflow**

```bash
cd ~/knowledge-vault
just sync
just draft test-migration concept
```

**Step 2: Validate and push**

```bash
just validate
just sync-push "docs: test migration"
```

**Step 3: Verify on GitHub**

Check commit appeared at github.com/sammasak/knowledge-vault

**Step 4: Clean up test**

```bash
rm -rf Drafts/test-migration/
just sync-push "docs: remove test"
```

---

## Success Criteria

- [ ] Vault at ~/knowledge-vault
- [ ] Obsidian MCP removed
- [ ] Unified skill works
- [ ] Auto-sync functional
- [ ] All hosts can access vault
- [ ] Git workflow works

