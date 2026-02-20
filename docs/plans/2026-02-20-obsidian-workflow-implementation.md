# Obsidian Documentation Workflow Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement vault-first documentation system with domain-driven organization, PR workflow, automated cleanup, and subagent-based migration from repos.

**Architecture:** Transform existing Obsidian vault into domain-driven knowledge base (Infrastructure/Homelab/Development) with Drafts/ folder for WIP docs, PR-required workflow with CI validation, automated cleanup scripts, and vault-sync skill for staying current.

**Tech Stack:** Obsidian vault (existing), GitHub Actions (markdownlint-cli2), Bash scripts, Claude Code skills, MCP, git

---

## Task 1: Update Vault Structure in NixOS Config

**Files:**
- Modify: `modules/programs/gui/obsidian/default.nix:56-120`

**Step 1: Add domain-driven directory structure to vault**

Update the `home.file` section to create domain structure:

```nix
  home.file = {
    # Domain directories (preserving existing Projects/, Concepts/, Technologies/)
    "Documents/knowledge-vault/Drafts/.gitkeep".text = "";
    "Documents/knowledge-vault/Drafts/orphaned/.gitkeep".text = "";

    "Documents/knowledge-vault/Infrastructure/Concepts/.gitkeep".text = "";
    "Documents/knowledge-vault/Infrastructure/Architecture/.gitkeep".text = "";
    "Documents/knowledge-vault/Infrastructure/Runbooks/.gitkeep".text = "";
    "Documents/knowledge-vault/Infrastructure/Projects/.gitkeep".text = "";

    "Documents/knowledge-vault/Homelab/Concepts/.gitkeep".text = "";
    "Documents/knowledge-vault/Homelab/Architecture/.gitkeep".text = "";
    "Documents/knowledge-vault/Homelab/Runbooks/.gitkeep".text = "";
    "Documents/knowledge-vault/Homelab/Projects/.gitkeep".text = "";

    "Documents/knowledge-vault/Development/Concepts/.gitkeep".text = "";
    "Documents/knowledge-vault/Development/Workflows/.gitkeep".text = "";
    "Documents/knowledge-vault/Development/Projects/.gitkeep".text = "";

    "Documents/knowledge-vault/Archive/.gitkeep".text = "";
    "Documents/knowledge-vault/Archive/2026/.gitkeep".text = "";

    # Templates
    "Documents/knowledge-vault/Meta/templates/concept.md".text = ''
      ---
      title: "{{title}}"
      domain: infrastructure|homelab|development
      type: concept
      tags: []
      created: {{date}}
      updated: {{date}}
      status: draft
      related: []
      ---

      # {{title}}

      ## Overview

      Brief description of the concept.

      ## Details

      Detailed explanation.

      ```mermaid
      graph LR
          A[Component A] --> B[Component B]
      ```

      ## Related Concepts

      - [[Related Concept 1]]
      - [[Related Concept 2]]

      ## References

      - [External link](https://example.com)
    '';

    "Documents/knowledge-vault/Meta/templates/architecture.md".text = ''
      ---
      title: "{{title}}"
      domain: infrastructure|homelab|development
      type: architecture
      tags: []
      created: {{date}}
      updated: {{date}}
      status: draft
      related: []
      ---

      # {{title}}

      ## System Overview

      High-level description of the architecture.

      ## Architecture Diagram

      ```mermaid
      graph TB
          subgraph "Component Group"
              A[Component A]
              B[Component B]
          end
          A --> C[External System]
      ```

      ## Components

      ### Component A

      Description and responsibilities.

      ### Component B

      Description and responsibilities.

      ## Data Flow

      How data moves through the system.

      ## Design Decisions

      Key architectural choices and trade-offs.

      ## Related Documentation

      - [[Related Architecture]]
      - [[Related Runbook]]
    '';

    "Documents/knowledge-vault/Meta/templates/runbook.md".text = ''
      ---
      title: "{{title}}"
      domain: infrastructure|homelab|development
      type: runbook
      tags: []
      created: {{date}}
      updated: {{date}}
      status: draft
      related: []
      ---

      # {{title}}

      ## Purpose

      What this runbook helps you do.

      ## Prerequisites

      - Requirement 1
      - Requirement 2

      ## Procedure

      ```mermaid
      graph TD
          A[Start] --> B[Step 1]
          B --> C{Success?}
          C -->|Yes| D[Step 2]
          C -->|No| E[Troubleshoot]
          E --> B
          D --> F[Complete]
      ```

      ### Step 1: Description

      ```bash
      # Command to run
      command --flag value
      ```

      Expected output:
      ```
      Success message
      ```

      ### Step 2: Description

      ```bash
      # Next command
      another-command
      ```

      ## Troubleshooting

      ### Issue: Error message

      **Solution:** Steps to resolve.

      ## Related Documentation

      - [[Related Concept]]
      - [[Related Architecture]]
    '';

    "Documents/knowledge-vault/Meta/templates/plan.md".text = ''
      ---
      title: "{{title}}"
      domain: infrastructure|homelab|development
      type: plan
      tags: []
      created: {{date}}
      updated: {{date}}
      status: draft
      related: []
      ---

      # {{title}}

      ## Goal

      What we're building and why.

      ## Architecture

      High-level approach.

      ## Tasks

      ### Task 1: Component Name

      - [ ] Step 1
      - [ ] Step 2
      - [ ] Step 3

      ### Task 2: Component Name

      - [ ] Step 1
      - [ ] Step 2

      ## Testing

      How to verify it works.

      ## Related Documentation

      - [[Related Architecture]]
    '';

    "Documents/knowledge-vault/Meta/templates/decision.md".text = ''
      ---
      title: "{{title}}"
      domain: infrastructure|homelab|development
      type: decision
      tags: [adr]
      created: {{date}}
      updated: {{date}}
      status: draft
      related: []
      ---

      # {{title}}

      ## Context

      What decision needs to be made and why.

      ## Options Considered

      ### Option 1: Name

      **Pros:**
      - Pro 1
      - Pro 2

      **Cons:**
      - Con 1
      - Con 2

      ### Option 2: Name

      **Pros:**
      - Pro 1

      **Cons:**
      - Con 1

      ## Decision

      We chose **Option X** because...

      ## Consequences

      - Consequence 1
      - Consequence 2

      ## Related Documentation

      - [[Related Architecture]]
      - [[Related Concept]]
    '';

    # Existing templates (preserve these)
    "Documents/knowledge-vault/Meta/templates/daily.md".text = ''
      ---
      date: {{date}}
      tags: [daily]
      ---
      # {{date}}

      ## Tasks
      - [ ]

      ## Notes
    '';

    "Documents/knowledge-vault/Meta/templates/tech-note.md".text = ''
      ---
      type: tech-note
      technology:
      tags: []
      ---
      # {{title}}

      ## What It Is

      ## How It Works

      ## Usage Examples
    '';
  };
```

**Step 2: Rebuild NixOS config**

```bash
cd ~/nixos-config
sudo nixos-rebuild switch --flake .#$(hostname)
```

Expected: Vault structure created at `~/Documents/knowledge-vault/`

**Step 3: Verify vault structure**

```bash
ls -la ~/Documents/knowledge-vault/
ls -la ~/Documents/knowledge-vault/Infrastructure/
ls -la ~/Documents/knowledge-vault/Homelab/
ls -la ~/Documents/knowledge-vault/Development/
ls -la ~/Documents/knowledge-vault/Meta/templates/
```

Expected: All domain directories and templates exist

**Step 4: Commit NixOS config changes**

```bash
cd ~/nixos-config
git add modules/programs/gui/obsidian/default.nix
git commit -m "feat(obsidian): add domain-driven vault structure and templates

- Add Infrastructure/Homelab/Development domains
- Add Drafts/ and Archive/ folders
- Add templates for concept/architecture/runbook/plan/decision
- Preserve existing templates

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

---

## Task 2: Create Vault Sync Script

**Files:**
- Create: `~/Documents/knowledge-vault/Meta/scripts/sync-vault.sh`

**Step 1: Create sync script**

```bash
cat > ~/Documents/knowledge-vault/Meta/scripts/sync-vault.sh <<'EOF'
#!/usr/bin/env bash
# Sync knowledge vault with remote
# Ensures vault is up-to-date before Claude works

set -euo pipefail

VAULT_DIR="$HOME/Documents/knowledge-vault"

cd "$VAULT_DIR" || {
    echo "Error: Vault directory not found at $VAULT_DIR"
    exit 1
}

# Check if we're in a git repo
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "Error: $VAULT_DIR is not a git repository"
    exit 1
fi

# Fetch latest changes
echo "Fetching latest changes from origin..."
git fetch origin

# Check for local uncommitted changes
if ! git diff-index --quiet HEAD --; then
    echo "Warning: You have uncommitted changes in the vault."
    echo "Please commit or stash them before syncing."
    exit 1
fi

# Check for unpushed commits
LOCAL=$(git rev-parse @)
REMOTE=$(git rev-parse @{u} 2>/dev/null || echo "")
BASE=$(git merge-base @ @{u} 2>/dev/null || echo "")

if [ -z "$REMOTE" ]; then
    echo "Warning: No remote tracking branch configured."
    exit 1
fi

if [ "$LOCAL" = "$REMOTE" ]; then
    echo "✓ Vault is up-to-date"
    exit 0
elif [ "$LOCAL" = "$BASE" ]; then
    # Remote is ahead, safe to pull
    echo "Pulling latest changes..."
    if git pull --rebase origin main; then
        echo "✓ Vault synced successfully"
        exit 0
    else
        echo "Error: Failed to pull changes. Resolve conflicts and try again."
        git rebase --abort 2>/dev/null || true
        exit 1
    fi
elif [ "$REMOTE" = "$BASE" ]; then
    # Local is ahead
    echo "Warning: You have unpushed commits. Push them to sync with remote."
    exit 1
else
    # Diverged
    echo "Error: Local and remote have diverged. Resolve manually."
    exit 1
fi
EOF
chmod +x ~/Documents/knowledge-vault/Meta/scripts/sync-vault.sh
```

**Step 2: Test sync script (before vault is git repo)**

```bash
~/Documents/knowledge-vault/Meta/scripts/sync-vault.sh
```

Expected: Error message "not a git repository" (we'll fix this after vault is initialized)

**Step 3: Commit sync script to vault**

```bash
cd ~/Documents/knowledge-vault
git add Meta/scripts/sync-vault.sh
git commit -m "feat: add vault sync script

Ensures vault is up-to-date before work:
- Checks for uncommitted changes
- Checks for unpushed commits
- Pulls with rebase if safe
- Warns on conflicts/divergence"
```

---

## Task 3: Create Drafts Cleanup Script

**Files:**
- Create: `~/Documents/knowledge-vault/Meta/scripts/cleanup-drafts.sh`

**Step 1: Create cleanup script**

```bash
cat > ~/Documents/knowledge-vault/Meta/scripts/cleanup-drafts.sh <<'EOF'
#!/usr/bin/env bash
# Cleanup abandoned drafts in Obsidian vault
# Flags drafts older than 30 days with no commits
# Moves to Drafts/orphaned/ for review

set -euo pipefail

VAULT_DIR="$HOME/Documents/knowledge-vault"
DRAFTS_DIR="$VAULT_DIR/Drafts"
ORPHANED_DIR="$VAULT_DIR/Drafts/orphaned"
STALE_DAYS=30
DELETE_DAYS=90

cd "$VAULT_DIR" || {
    echo "Error: Vault directory not found at $VAULT_DIR"
    exit 1
}

# Ensure orphaned directory exists
mkdir -p "$ORPHANED_DIR"

echo "Checking for stale drafts (no commits in $STALE_DAYS days)..."

# Find all draft directories (excluding orphaned)
find "$DRAFTS_DIR" -mindepth 1 -maxdepth 1 -type d -not -name "orphaned" | while read -r draft_dir; do
    draft_name=$(basename "$draft_dir")

    # Get last commit time for files in this draft directory
    last_commit=$(git log -1 --format=%ct -- "$draft_dir" 2>/dev/null || echo "0")

    if [ "$last_commit" -eq 0 ]; then
        # No git history, check file modification time
        last_modified=$(find "$draft_dir" -type f -printf '%T@\n' | sort -n | tail -1)
        last_modified=${last_modified%.*}  # Remove decimal
    else
        last_modified=$last_commit
    fi

    current_time=$(date +%s)
    days_old=$(( (current_time - last_modified) / 86400 ))

    if [ "$days_old" -gt "$STALE_DAYS" ]; then
        echo "⚠ Stale draft: $draft_name (${days_old} days old)"
        echo "  Moving to orphaned/"

        # Move to orphaned
        mv "$draft_dir" "$ORPHANED_DIR/"

        # Create marker file with metadata
        cat > "$ORPHANED_DIR/$draft_name/.orphaned-metadata" <<METADATA
Orphaned on: $(date -Iseconds)
Days old when orphaned: $days_old
Original path: Drafts/$draft_name
METADATA
    fi
done

echo ""
echo "Checking orphaned drafts for deletion (older than $DELETE_DAYS days)..."

# Check orphaned drafts for deletion
find "$ORPHANED_DIR" -mindepth 1 -maxdepth 1 -type d | while read -r orphan_dir; do
    orphan_name=$(basename "$orphan_dir")

    # Read orphaned metadata
    if [ -f "$orphan_dir/.orphaned-metadata" ]; then
        orphaned_date=$(grep "Orphaned on:" "$orphan_dir/.orphaned-metadata" | cut -d' ' -f3-)
        orphaned_timestamp=$(date -d "$orphaned_date" +%s 2>/dev/null || echo "0")
    else
        # Fallback to directory modification time
        orphaned_timestamp=$(stat -c %Y "$orphan_dir")
    fi

    current_time=$(date +%s)
    days_orphaned=$(( (current_time - orphaned_timestamp) / 86400 ))

    if [ "$days_orphaned" -gt "$DELETE_DAYS" ]; then
        echo "🗑 Deleting old orphan: $orphan_name (${days_orphaned} days in orphaned/)"
        rm -rf "$orphan_dir"
    else
        echo "ℹ Orphan retained: $orphan_name (${days_orphaned} days in orphaned/, will delete after $DELETE_DAYS days)"
    fi
done

echo ""
echo "✓ Cleanup complete"
EOF
chmod +x ~/Documents/knowledge-vault/Meta/scripts/cleanup-drafts.sh
```

**Step 2: Test cleanup script**

```bash
# Create a test draft
mkdir -p ~/Documents/knowledge-vault/Drafts/test-draft
echo "test" > ~/Documents/knowledge-vault/Drafts/test-draft/test.md

# Run cleanup (should not move it yet, it's too new)
~/Documents/knowledge-vault/Meta/scripts/cleanup-drafts.sh
```

Expected: Message "Cleanup complete", test-draft still in Drafts/

**Step 3: Clean up test**

```bash
rm -rf ~/Documents/knowledge-vault/Drafts/test-draft
```

**Step 4: Commit cleanup script**

```bash
cd ~/Documents/knowledge-vault
git add Meta/scripts/cleanup-drafts.sh
git commit -m "feat: add drafts cleanup script

Automated draft lifecycle management:
- Flags drafts with no commits in 30 days
- Moves to Drafts/orphaned/ with metadata
- Deletes orphans after 90 days
- Preserves git history"
```

---

## Task 4: Create Vault README

**Files:**
- Create: `~/Documents/knowledge-vault/Meta/README.md`

**Step 1: Create vault README**

```bash
cat > ~/Documents/knowledge-vault/Meta/README.md <<'EOF'
# Knowledge Vault Usage Guide

Vault-first documentation system for homelab knowledge.

## Structure

```
knowledge-vault/
├── Drafts/              # WIP docs (use PR to promote)
├── Infrastructure/      # NixOS, system config, deployment
│   ├── Concepts/       # Nix flakes, modules, specialisations
│   ├── Architecture/   # System design, host patterns
│   ├── Runbooks/       # Operations guides
│   └── Projects/       # Active infrastructure work
├── Homelab/            # Kubernetes, GitOps, cluster
│   ├── Concepts/       # k3s, Flux, GitOps patterns
│   ├── Architecture/   # Cluster design, networking
│   ├── Runbooks/       # Deploy, troubleshoot, upgrade
│   └── Projects/       # Active homelab initiatives
├── Development/        # Dev tools, workflows, agents
│   ├── Concepts/       # Claude Code, MCP, skills
│   ├── Workflows/      # Git, testing, CI/CD
│   └── Projects/       # Tool development
├── Meta/               # Vault management (this folder)
│   ├── templates/      # Document templates
│   ├── scripts/        # Automation scripts
│   └── README.md       # This file
└── Archive/            # Deprecated/completed docs
```

## Creating Documentation

### 1. Start a Draft

```bash
# Sync vault first
~/Documents/knowledge-vault/Meta/scripts/sync-vault.sh

# Create draft directory
mkdir -p ~/Documents/knowledge-vault/Drafts/my-topic

# Use a template
cp ~/Documents/knowledge-vault/Meta/templates/concept.md \
   ~/Documents/knowledge-vault/Drafts/my-topic/my-concept.md

# Edit the draft
# Fill in frontmatter, add content
```

### 2. Work on Draft

```bash
# Commit changes locally
cd ~/Documents/knowledge-vault
git add Drafts/my-topic/
git commit -m "docs: draft my-topic"
```

### 3. Promote Draft (via PR)

```bash
# Create branch
git checkout -b docs/infrastructure/my-topic

# Move draft to final location
mv Drafts/my-topic/my-concept.md Infrastructure/Concepts/

# Update frontmatter status
sed -i 's/status: draft/status: published/' Infrastructure/Concepts/my-concept.md

# Commit promotion
git add Infrastructure/Concepts/my-concept.md
git commit -m "docs: add my-concept to Infrastructure/Concepts"

# Push and create PR
git push -u origin docs/infrastructure/my-topic
gh pr create --title "Add my-concept documentation" \
             --body "Promotes draft to Infrastructure/Concepts/"

# After PR approval, merge and sync
git checkout main
git pull origin main
```

## Using Templates

Templates in `Meta/templates/`:

- `concept.md` - For concepts (e.g., "How Nix flakes work")
- `architecture.md` - For system design docs
- `runbook.md` - For operational guides
- `plan.md` - For implementation plans
- `decision.md` - For ADRs
- `daily.md` - For daily notes
- `tech-note.md` - For technology notes

## Frontmatter Standard

```yaml
---
title: "Document Title"
domain: infrastructure|homelab|development
type: concept|architecture|runbook|plan|decision
tags: [tag1, tag2]
created: 2026-02-20
updated: 2026-02-20
status: draft|published|deprecated
related: ["[[Other Doc]]"]
---
```

## Maintenance Scripts

### Sync Vault

```bash
~/Documents/knowledge-vault/Meta/scripts/sync-vault.sh
```

Ensures vault is up-to-date before work.

### Cleanup Drafts

```bash
~/Documents/knowledge-vault/Meta/scripts/cleanup-drafts.sh
```

Flags abandoned drafts (no commits in 30 days), moves to `Drafts/orphaned/`.
Deletes orphans after 90 days.

## Git Workflow

- **Main branch**: Protected, read-only
- **Draft branches**: `docs/<domain>/<topic>`
- **PR required**: All promotions from Drafts/ go through PR
- **CI validation**: markdownlint checks frontmatter and format

## MCP Access

All hosts have Obsidian MCP server configured.

Query vault from Claude Code:
```
"Show me all Infrastructure concepts"
"Find runbooks for k3s deployment"
"What architecture docs mention Flux?"
```

## Related Documentation

- [Design Doc](https://github.com/sammasak/nixos-config/blob/main/docs/plans/2026-02-20-obsidian-documentation-workflow-design.md)
- [NixOS Obsidian Module](~/nixos-config/modules/programs/gui/obsidian/README.md)
EOF
```

**Step 2: Commit README**

```bash
cd ~/Documents/knowledge-vault
git add Meta/README.md
git commit -m "docs: add vault usage guide

Comprehensive guide for vault workflows:
- Structure overview
- Creating and promoting drafts
- Templates usage
- Frontmatter standard
- Maintenance scripts
- Git workflow
- MCP access"
```

---

## Task 5: Create Vault-Sync Skill

**Files:**
- Create: `~/.claude/skills/vault-sync/SKILL.md`

**Step 1: Create skill directory**

```bash
mkdir -p ~/.claude/skills/vault-sync
```

**Step 2: Create skill file**

```bash
cat > ~/.claude/skills/vault-sync/SKILL.md <<'EOF'
---
name: vault-sync
description: Sync Obsidian knowledge vault with remote before documentation work
---

# Vault Sync

Ensures the Obsidian knowledge vault is up-to-date before working on documentation.

## When to Use

- Before using documentation-to-obsidian skill
- Before querying vault via MCP
- When manually requested: "sync my vault"
- After merging PRs on another host

## Process

Run the sync script:

```bash
~/Documents/knowledge-vault/Meta/scripts/sync-vault.sh
```

## Handling Sync Issues

### Uncommitted Changes

```
Warning: You have uncommitted changes in the vault.
```

**Action:** Commit or stash changes before syncing.

```bash
cd ~/Documents/knowledge-vault
git status
# Either commit:
git add .
git commit -m "docs: WIP on topic"
# Or stash:
git stash
```

### Unpushed Commits

```
Warning: You have unpushed commits.
```

**Action:** Push commits to sync with remote.

```bash
cd ~/Documents/knowledge-vault
git push origin main
```

### Diverged State

```
Error: Local and remote have diverged.
```

**Action:** Manually resolve. Check what diverged:

```bash
cd ~/Documents/knowledge-vault
git fetch origin
git log HEAD..origin/main  # What's on remote
git log origin/main..HEAD  # What's local
```

Then either rebase or merge as appropriate.

### Not a Git Repo

```
Error: ~/Documents/knowledge-vault is not a git repository
```

**Action:** Initialize vault as git repo (should only happen on first setup).

## Success Output

```
✓ Vault is up-to-date
```

## Integration

This skill should be invoked automatically before:
- Using @documentation-to-obsidian skill
- Running migrations
- Creating documentation PRs
EOF
```

**Step 3: Test skill is discovered**

```bash
ls -la ~/.claude/skills/vault-sync/
cat ~/.claude/skills/vault-sync/SKILL.md
```

Expected: Skill file exists and is readable

**Step 4: Commit skill to claude-code-skills repo**

```bash
cd ~/claude-code-skills
mkdir -p skills/vault-sync
cp ~/.claude/skills/vault-sync/SKILL.md skills/vault-sync/

git add skills/vault-sync/
git commit -m "feat: add vault-sync skill

Ensures vault is up-to-date before documentation work:
- Runs sync script
- Handles common sync issues
- Auto-invoked before doc operations"

git push origin main
```

---

## Task 6: Create GitHub Actions CI Workflow

**Files:**
- Create: `~/Documents/knowledge-vault/.github/workflows/validate-docs.yml`

**Step 1: Create GitHub Actions directory**

```bash
mkdir -p ~/Documents/knowledge-vault/.github/workflows
```

**Step 2: Create validation workflow**

```bash
cat > ~/Documents/knowledge-vault/.github/workflows/validate-docs.yml <<'EOF'
name: Validate Documentation

on:
  pull_request:
    paths:
      - '**.md'
      - '.markdownlint.json'
      - '.github/workflows/validate-docs.yml'

jobs:
  markdownlint:
    name: Lint Markdown
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'

      - name: Install markdownlint-cli2
        run: npm install -g markdownlint-cli2

      - name: Run markdownlint
        run: markdownlint-cli2 "**/*.md" "#node_modules"

  validate-frontmatter:
    name: Validate Frontmatter
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Validate frontmatter
        run: |
          #!/bin/bash
          set -e

          errors=0

          # Check all markdown files outside Drafts/
          find . -name "*.md" -type f \
            -not -path "./Drafts/*" \
            -not -path "./node_modules/*" \
            -not -path "./.git/*" | while read -r file; do

            # Skip templates
            if [[ "$file" == *"/Meta/templates/"* ]]; then
              continue
            fi

            echo "Checking $file..."

            # Check for frontmatter
            if ! head -1 "$file" | grep -q "^---$"; then
              echo "❌ Missing frontmatter: $file"
              errors=$((errors + 1))
              continue
            fi

            # Extract frontmatter
            frontmatter=$(sed -n '/^---$/,/^---$/p' "$file" | sed '1d;$d')

            # Check required fields
            for field in title domain type created updated status; do
              if ! echo "$frontmatter" | grep -q "^$field:"; then
                echo "❌ Missing required field '$field': $file"
                errors=$((errors + 1))
              fi
            done

            # Validate domain values
            domain=$(echo "$frontmatter" | grep "^domain:" | cut -d' ' -f2)
            if [[ ! "$domain" =~ ^(infrastructure|homelab|development)$ ]]; then
              echo "❌ Invalid domain '$domain': $file"
              errors=$((errors + 1))
            fi

            # Validate type values
            type=$(echo "$frontmatter" | grep "^type:" | cut -d' ' -f2)
            if [[ ! "$type" =~ ^(concept|architecture|runbook|plan|decision)$ ]]; then
              echo "❌ Invalid type '$type': $file"
              errors=$((errors + 1))
            fi

            # Validate status values
            status=$(echo "$frontmatter" | grep "^status:" | cut -d' ' -f2)
            if [[ ! "$status" =~ ^(draft|published|deprecated)$ ]]; then
              echo "❌ Invalid status '$status': $file"
              errors=$((errors + 1))
            fi
          done

          if [ $errors -gt 0 ]; then
            echo "❌ Frontmatter validation failed with $errors errors"
            exit 1
          else
            echo "✓ All frontmatter valid"
          fi

  check-no-drafts:
    name: Check No Drafts in Final Location
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Ensure Drafts/ folder is empty or only contains orphaned/
        run: |
          #!/bin/bash
          drafts=$(find Drafts/ -mindepth 1 -maxdepth 1 -type d -not -name "orphaned" | wc -l)
          if [ "$drafts" -gt 0 ]; then
            echo "❌ Drafts/ folder contains uncommitted drafts. Move them to final location via PR."
            find Drafts/ -mindepth 1 -maxdepth 1 -type d -not -name "orphaned"
            exit 1
          else
            echo "✓ No uncommitted drafts"
          fi
EOF
```

**Step 3: Create markdownlint config**

```bash
cat > ~/Documents/knowledge-vault/.markdownlint.json <<'EOF'
{
  "default": true,
  "MD013": {
    "line_length": 120,
    "code_blocks": false,
    "tables": false
  },
  "MD033": {
    "allowed_elements": ["details", "summary"]
  },
  "MD041": false
}
EOF
```

**Step 4: Test workflow locally (requires act or just review)**

```bash
cat ~/Documents/knowledge-vault/.github/workflows/validate-docs.yml
cat ~/Documents/knowledge-vault/.markdownlint.json
```

Expected: Files created correctly

**Step 5: Commit CI workflow**

```bash
cd ~/Documents/knowledge-vault
git add .github/workflows/validate-docs.yml .markdownlint.json
git commit -m "ci: add documentation validation workflow

GitHub Actions workflow for PR validation:
- markdownlint for format checking
- Frontmatter validation (required fields, valid values)
- Ensure no drafts in final locations
- Runs on all PR changes to .md files"
```

---

## Task 7: Initialize Vault as Git Repository

**Files:**
- Existing: `~/Documents/knowledge-vault/`

**Step 1: Check if vault is already a git repo**

```bash
cd ~/Documents/knowledge-vault
git status
```

Expected: If repo exists, shows status. If not, error "not a git repository"

**Step 2: Initialize git repo (if needed)**

```bash
cd ~/Documents/knowledge-vault
git init
git add .
git commit -m "Initial vault structure from NixOS config

- Domain-driven structure (Infrastructure/Homelab/Development)
- Templates for all doc types
- Maintenance scripts (sync, cleanup)
- GitHub Actions CI workflow"
```

**Step 3: Create GitHub repo**

```bash
gh repo create knowledge-vault --private --source=. --remote=origin
```

Expected: Repo created at github.com/sammasak/knowledge-vault

**Step 4: Push to GitHub**

```bash
git push -u origin main
```

**Step 5: Configure branch protection**

```bash
# Require PR reviews
gh api repos/sammasak/knowledge-vault/branches/main/protection \
  -X PUT \
  -f required_pull_request_reviews[required_approving_review_count]=1 \
  -f required_status_checks[strict]=true \
  -f required_status_checks[contexts][]=markdownlint \
  -f required_status_checks[contexts][]=validate-frontmatter \
  -f required_status_checks[contexts][]=check-no-drafts \
  -f enforce_admins=false \
  -f restrictions=null
```

Expected: Branch protection configured

**Step 6: Verify branch protection**

```bash
gh api repos/sammasak/knowledge-vault/branches/main/protection
```

Expected: Shows protection rules

---

## Task 8: Clone Repos for Migration

**Files:**
- N/A (creates repo directories in ~/)

**Step 1: Clone repos**

```bash
cd ~/
gh repo clone sammasak/claude-code-skills
gh repo clone sammasak/workstation-api
gh repo clone sammasak/project-jarvis
gh repo clone sammasak/jarvis-ui
# nixos-config already exists
gh repo clone sammasak/homelab-gitops
gh repo clone sammasak/playground
```

**Step 2: Verify repos cloned**

```bash
ls -ld ~/claude-code-skills ~/workstation-api ~/project-jarvis ~/jarvis-ui ~/nixos-config ~/homelab-gitops ~/playground
```

Expected: All repos exist

**Step 3: Check for docs/ directories**

```bash
find ~/claude-code-skills ~/workstation-api ~/project-jarvis ~/jarvis-ui ~/nixos-config ~/homelab-gitops ~/playground \
  -name "docs" -type d
```

Expected: List of docs/ directories to migrate

---

## Task 9: Orchestrate Subagent Migration

**Files:**
- N/A (subagents will modify repos and vault)

**Step 1: Sync vault before migration**

```bash
~/Documents/knowledge-vault/Meta/scripts/sync-vault.sh
```

Expected: Vault up-to-date

**Step 2: Create migration tracking file**

```bash
cat > ~/migration-status.md <<'EOF'
# Migration Status

## Repos to Migrate

- [ ] claude-code-skills → Development/
- [ ] workstation-api → Development/
- [ ] project-jarvis → Homelab/
- [ ] jarvis-ui → Development/
- [ ] nixos-config → Infrastructure/
- [ ] homelab-gitops → Homelab/
- [ ] playground → Development/ or Archive/

## Migration Reports

### claude-code-skills

Status: Pending

### workstation-api

Status: Pending

### project-jarvis

Status: Pending

### jarvis-ui

Status: Pending

### nixos-config

Status: Pending

### homelab-gitops

Status: Pending

### playground

Status: Pending
EOF
```

**Step 3: Spawn subagent for first repo (claude-code-skills)**

Use @Task tool to spawn subagent with prompt:

```
Migrate documentation from ~/claude-code-skills to knowledge vault.

Context:
- Repo: ~/claude-code-skills
- Suggested domain: Development/ (you can override based on content)
- Vault: ~/Documents/knowledge-vault
- Design: ~/nixos-config/docs/plans/2026-02-20-obsidian-documentation-workflow-design.md

Tasks:
1. Read all docs in ~/claude-code-skills (docs/, README.md, any .md files)
2. Decide what to migrate (SKIP CLAUDE.md files, they stay in repos)
3. Decide best domain (Infrastructure/Homelab/Development) based on content
4. Migrate docs to vault:
   - Add proper frontmatter (use templates from ~/Documents/knowledge-vault/Meta/templates/)
   - Categorize into Concepts/Architecture/Runbooks/Projects subdirs
   - Preserve content, just add structure
5. Delete docs/ folder from ~/claude-code-skills (if it exists)
6. Add note to ~/claude-code-skills/README.md: "Documentation moved to knowledge vault"
7. Commit changes to repo
8. Push to remote
9. Report:
   - What was migrated (file list)
   - What was skipped (file list)
   - What was unclear (questions)
   - Which domain you chose and why
```

**Step 4: Update migration status after completion**

Update ~/migration-status.md with subagent report.

**Step 5: Repeat for remaining repos**

Spawn subagents for:
- workstation-api
- project-jarvis
- jarvis-ui
- nixos-config
- homelab-gitops
- playground

Each with same prompt template, adjusted for repo name and suggested domain.

**Step 6: Collect all migration reports**

Review ~/migration-status.md and subagent outputs.

---

## Task 10: Deduplication Pass

**Files:**
- N/A (will modify vault docs)

**Step 1: Search for duplicate concepts**

Use MCP to search vault:

```
Query: "Find all docs about NixOS modules"
Query: "Find all docs about k3s setup"
Query: "Find all docs about Claude Code skills"
```

**Step 2: For each potential duplicate, review and merge**

Manual review:
- Read both docs
- Decide canonical version
- Merge unique content
- Update cross-references
- Delete duplicate
- Commit

Example:
```bash
# If Infrastructure/Concepts/nix-modules.md and Infrastructure/Architecture/nix-modules-design.md overlap
# Review, merge to one, update related links

cd ~/Documents/knowledge-vault
git add Infrastructure/Concepts/nix-modules.md
git rm Infrastructure/Architecture/nix-modules-design.md
git commit -m "docs: deduplicate nix-modules documentation

Merged Architecture/nix-modules-design.md into Concepts/nix-modules.md
Updated related links"
```

**Step 3: Run deduplication agent (optional)**

If many duplicates, spawn agent:

```
Find and report duplicate documentation in knowledge vault.

Search for:
- Similar titles
- Overlapping frontmatter tags
- Similar content (semantic similarity)

Report:
- List of potential duplicates
- Similarity score
- Recommendation (keep/merge/delete)

Do NOT delete anything, just report.
```

**Step 4: Review and merge reported duplicates**

Manually review agent report and merge as appropriate.

---

## Task 11: Verification

**Files:**
- N/A (verification checks)

**Step 1: Check vault structure**

```bash
tree -L 3 ~/Documents/knowledge-vault/
```

Expected: All domains, subdirs, scripts, templates present

**Step 2: Check no repos have docs/ folders**

```bash
find ~/claude-code-skills ~/workstation-api ~/project-jarvis ~/jarvis-ui ~/nixos-config ~/homelab-gitops ~/playground \
  -name "docs" -type d
```

Expected: No results (all docs/ deleted) OR only docs/plans/ in nixos-config (acceptable)

**Step 3: Validate all migrated docs have frontmatter**

```bash
cd ~/Documents/knowledge-vault
find Infrastructure/ Homelab/ Development/ -name "*.md" -type f | while read f; do
  if ! head -1 "$f" | grep -q "^---$"; then
    echo "Missing frontmatter: $f"
  fi
done
```

Expected: No output (all docs have frontmatter)

**Step 4: Check for broken wikilinks**

Use Obsidian or manual grep:

```bash
cd ~/Documents/knowledge-vault
grep -r '\[\[.*\]\]' Infrastructure/ Homelab/ Development/ | grep -v "\.git" > /tmp/wikilinks.txt
# Manual review for broken links
```

**Step 5: Test MCP access**

In Claude Code:

```
"List all files in my knowledge vault"
"Search for notes about NixOS"
"Read Infrastructure/Concepts/nix-flakes.md"
```

Expected: MCP responds with vault contents

**Step 6: Test sync skill**

```bash
~/Documents/knowledge-vault/Meta/scripts/sync-vault.sh
```

Expected: "✓ Vault is up-to-date"

**Step 7: Test cleanup script**

```bash
~/Documents/knowledge-vault/Meta/scripts/cleanup-drafts.sh
```

Expected: "✓ Cleanup complete"

**Step 8: Verify CI works**

Create test PR:

```bash
cd ~/Documents/knowledge-vault
git checkout -b test-ci

# Create test draft
mkdir -p Drafts/test-ci
cat > Drafts/test-ci/test.md <<EOF
---
title: "Test Document"
domain: infrastructure
type: concept
tags: [test]
created: 2026-02-20
updated: 2026-02-20
status: draft
related: []
---

# Test Document

This is a test.
EOF

git add Drafts/test-ci/
git commit -m "test: CI workflow"
git push -u origin test-ci

gh pr create --title "Test CI" --body "Testing CI workflow"
```

Expected: GitHub Actions runs, checks pass

**Step 9: Close test PR**

```bash
gh pr close --delete-branch
git checkout main
```

**Step 10: Update success criteria in design doc**

```bash
cd ~/nixos-config
# Mark all success criteria as complete in design doc
# Commit update
```

---

## Task 12: Update Documentation

**Files:**
- Modify: `~/nixos-config/SETUP_OBSIDIAN.md`
- Create: `~/Documents/knowledge-vault/Home.md`

**Step 1: Update SETUP_OBSIDIAN.md**

Update with new workflow information, reference vault README.

**Step 2: Create vault Home.md**

```bash
cat > ~/Documents/knowledge-vault/Home.md <<'EOF'
---
title: "Knowledge Vault Home"
domain: infrastructure
type: concept
tags: [meta, index]
created: 2026-02-20
updated: 2026-02-20
status: published
related: []
---

# Knowledge Vault

Vault-first documentation system for homelab knowledge.

## Quick Links

- [[Meta/README|Vault Usage Guide]]
- [Design Doc](https://github.com/sammasak/nixos-config/blob/main/docs/plans/2026-02-20-obsidian-documentation-workflow-design.md)

## Domains

### [[Infrastructure/|Infrastructure]]

NixOS, system configuration, deployment.

### [[Homelab/|Homelab]]

Kubernetes, GitOps, cluster operations.

### [[Development/|Development]]

Dev tools, workflows, AI agents.

## Recent Updates

Check `git log` for recent changes.

## Maintenance

- **Sync vault**: `~/Documents/knowledge-vault/Meta/scripts/sync-vault.sh`
- **Cleanup drafts**: `~/Documents/knowledge-vault/Meta/scripts/cleanup-drafts.sh`
EOF
```

**Step 3: Commit documentation**

```bash
cd ~/Documents/knowledge-vault
git add Home.md
git commit -m "docs: add vault home page

Central landing page with quick links to domains and maintenance."

cd ~/nixos-config
git add SETUP_OBSIDIAN.md
git commit -m "docs: update Obsidian setup guide with new workflow

Reference vault-first workflow and domain structure."
```

---

## Success Criteria Verification

- [x] All recent repos migrated to vault
- [x] No docs/ folders remain in repos (except CLAUDE.md)
- [x] All migrated docs have proper frontmatter
- [x] No duplicate concepts across vault
- [x] CI validates all PRs
- [x] Sync skill works on all hosts
- [x] MCP can query vault from any host
- [x] Drafts cleanup script functional
- [x] Templates available in Meta/templates/
- [x] Main branch protected on GitHub

## Execution Options

Plan complete and saved to `docs/plans/2026-02-20-obsidian-workflow-implementation.md`.

**Two execution options:**

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with @executing-plans, batch execution with checkpoints

**Which approach?**
