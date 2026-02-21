# Knowledge Vault Improvements Design

**Date:** 2026-02-21
**Status:** Approved
**Author:** Claude + User

## Overview

Improve the knowledge-vault setup by:
1. Moving vault from `~/Documents/knowledge-vault` to `~/knowledge-vault` for simpler path
2. Removing Obsidian MCP server in favor of direct file operations
3. Creating a unified Claude skill that handles all vault operations through Justfile automation
4. Ensuring automatic git sync on every vault modification

## Goals

- **Simplicity**: Reduce complexity by removing MCP dependency
- **Automation**: Auto-sync vault changes to remote on every operation
- **Consistency**: Standardized path across all hosts
- **Maintainability**: Single unified skill instead of 4 separate skills

## Architecture

### Vault Location

**Current:** `~/Documents/knowledge-vault`
**New:** `~/knowledge-vault`

- Standardized across all NixOS hosts
- Simpler path, easier to access
- No per-host configuration needed

### Obsidian MCP Removal

**Rationale:**
- MCP adds complexity without significant benefit
- Direct file operations (Read, Write, Edit) are sufficient
- Justfile already provides git automation
- Skills can enforce patterns and validations better than MCP

**Changes:**
- Remove `obsidian` MCP server from `modules/programs/cli/claude-code/mcp.nix`
- Vault operations use native Claude tools (Read, Write, Edit, Bash)

### Skill-Based Workflow

**Single Unified Skill:** `knowledge-vault`

Replaces 4 existing skills:
- `document-to-vault` → archived
- `documentation-to-obsidian` → archived
- `manage-project-in-vault` → archived
- `vault-sync` → archived

**Skill Responsibilities:**
- Guide document creation with templates
- Guide document updates and editing
- Guide project management workflows
- Enforce auto-sync pattern (sync before, push after)
- Provide error handling and troubleshooting

### Git Integration

**Auto-Sync Pattern:**
1. Always `just sync` before operations (pull latest)
2. Perform vault operation (create/update document)
3. Always `just sync-push "message"` after changes (commit + push)

**Benefits:**
- All hosts stay synchronized
- No manual git operations needed
- Prevents merge conflicts
- Clear audit trail in git history

### Justfile as Automation Layer

**Separation of Concerns:**
- **Justfile:** Automation engine (git ops, validation, drafts, promotion)
- **Skill:** Workflow guidance (when to use Justfile, how to structure content)

**New Justfile Command:**
```just
# Sync and push changes with commit message
sync-push message:
    @just sync
    git add .
    git commit -m "{{message}}"
    git push origin main
```

Simplifies skill's auto-sync pattern to single command.

## Components

### NixOS Configuration Changes

#### 1. `modules/programs/gui/obsidian/default.nix`

Update vault path from `Documents/knowledge-vault` to `knowledge-vault`:

```nix
vaults.main = {
  enable = true;
  target = "knowledge-vault";  # was: "Documents/knowledge-vault"
```

Update all `home.file` paths:
```nix
home.file = {
  "knowledge-vault/Meta/templates/daily.md".text = ''...
  "knowledge-vault/Meta/templates/tech-note.md".text = ''...
  # ... all other paths
```

#### 2. `modules/programs/cli/claude-code/mcp.nix`

Remove obsidian MCP server (lines 35-44):
```nix
# DELETE THIS BLOCK:
obsidian = {
  command = "npx";
  args = [
    "-y"
    "@mauricio.wolff/mcp-obsidian@latest"
    "${config.home.homeDirectory}/Documents/knowledge-vault"
  ];
};
```

### Skill Structure

**File:** `claude-code-skills/skills/knowledge-vault/SKILL.md`

**Sections:**
1. **Overview** - What this skill does, when to use it
2. **Prerequisites** - Vault location, Justfile availability
3. **Core Operations:**
   - Document creation with templates
   - Document updates and editing
   - Project management
   - Vault synchronization
4. **Workflows** - Step-by-step procedures for common tasks
5. **Templates Reference** - Available templates and their use cases
6. **Examples** - Concrete usage scenarios
7. **Error Handling** - Common issues and solutions
8. **Integration** - How skill works with Justfile and git

### Skills Migration

**Archive Old Skills:**

In `claude-code-skills` repo:
```bash
mkdir -p .archived/vault-skills
mv skills/document-to-vault .archived/vault-skills/
mv skills/documentation-to-obsidian .archived/vault-skills/
mv skills/manage-project-in-vault .archived/vault-skills/
mv skills/vault-sync .archived/vault-skills/
```

**Create New Skill:**
```bash
mkdir -p skills/knowledge-vault
# Create comprehensive SKILL.md
```

### Justfile Enhancements

Add to `~/knowledge-vault/Justfile`:

```just
# Sync and push changes with commit message
sync-push message:
    @just sync
    git add .
    git commit -m "{{message}}"
    git push origin main
```

This combines sync + commit + push into a single atomic operation.

## Data Flow

### Document Creation Flow

```
User invokes knowledge-vault skill
  ↓
Skill guides:
  1. just sync              (pull latest changes)
  2. just draft <name> <template>  (create draft in Drafts/)
  3. Write tool to populate content  (with frontmatter)
  4. just validate          (check frontmatter)
  5. just sync-push "docs: draft <name>"  (commit + push)
```

### Document Update Flow

```
User invokes knowledge-vault skill
  ↓
Skill guides:
  1. just sync              (pull latest changes)
  2. Read tool to view current content
  3. Edit tool to modify sections
  4. just validate          (ensure still valid)
  5. just sync-push "docs: update <name>"  (commit + push)
```

### Draft Promotion Flow

```
User invokes knowledge-vault skill
  ↓
Skill guides:
  1. just sync              (pull latest changes)
  2. just promote <draft> <domain> <subdomain>  (creates PR)
  3. User reviews PR on GitHub
  4. After merge: git checkout main && git pull
```

### Project Management Flow

```
User invokes knowledge-vault skill
  ↓
Skill guides:
  1. just sync              (pull latest changes)
  2. Write tool to create project index
  3. Create architecture/decisions/plans using draft workflow
  4. Edit tool to update project status (patch sections)
  5. Each change auto-synced via just sync-push
```

## Error Handling

### Merge Conflicts

**Detection:** `just sync` fails with merge conflict message

**Handling:**
- Skill instructs user to resolve manually
- Provides git commands: `git status`, `git diff`, `git mergetool`
- After resolution: `git add . && git commit && git push`

**Prevention:** Always sync before operations

### Validation Failures

**Detection:** `just validate` reports missing frontmatter fields

**Handling:**
- Skill shows which fields are missing
- Provides frontmatter template examples
- User fixes fields, re-runs validation

**Prevention:** Skill enforces frontmatter template in creation workflow

### Vault Not Found

**Detection:** `~/knowledge-vault` directory doesn't exist

**Handling:**
- Skill provides setup instructions
- Clone vault: `git clone git@github.com:sammasak/knowledge-vault.git ~/knowledge-vault`
- Or: NixOS rebuild should create structure via home.file

**Prevention:** NixOS config creates vault structure automatically

### Justfile Missing

**Detection:** `just` command not found or Justfile doesn't exist in vault

**Handling:**
- Skill errors with clear message: "Vault not properly set up"
- Instructions to check vault integrity
- Re-clone or nixos-rebuild if needed

**Prevention:** Justfile is part of vault repo, should always exist

### Git Push Failures

**Detection:** `git push` fails (network error, auth failure, conflicts)

**Handling:**
- Check network connectivity
- Verify SSH keys: `ssh -T git@github.com`
- Check SOPS token is loaded: `echo $CLAUDE_CODE_OAUTH_TOKEN`
- Retry after resolving issue

**Prevention:**
- Proper SOPS token setup in NixOS config
- Sync before operations reduces conflict likelihood

## Testing Strategy

### NixOS Configuration Testing

```bash
# Build config to verify syntax
nix build .#nixosConfigurations.acer-swift.config.system.build.toplevel --no-link

# Check that vault path updated
grep -r "Documents/knowledge-vault" modules/
# Should return nothing

grep -r "knowledge-vault" modules/programs/gui/obsidian/default.nix
# Should show new path

# Verify Obsidian MCP removed
grep -A5 "obsidian = {" modules/programs/cli/claude-code/mcp.nix
# Should return nothing
```

### Skill Testing

1. **Document Creation:**
   - Invoke skill for new concept document
   - Verify it guides through: sync → draft → write → validate → push
   - Check document exists in vault with proper frontmatter
   - Verify git commit and push occurred

2. **Document Update:**
   - Invoke skill to update existing document
   - Verify it guides through: sync → read → edit → validate → push
   - Check changes reflected in vault
   - Verify git commit and push occurred

3. **Project Management:**
   - Invoke skill to create new project
   - Verify project structure created (index, architecture, plans)
   - Verify wikilinks work correctly
   - Verify all changes pushed to remote

4. **Error Scenarios:**
   - Test with vault not found (expect clear error)
   - Test with validation failure (expect helpful guidance)
   - Test with merge conflict (expect resolution instructions)

### Migration Testing

**Before Migration:**
```bash
# Verify current vault location
ls -la ~/Documents/knowledge-vault/.git

# Note current git remote
cd ~/Documents/knowledge-vault
git remote -v
```

**Migration Steps:**
```bash
# Move vault to new location
mv ~/Documents/knowledge-vault ~/knowledge-vault

# Verify git still works
cd ~/knowledge-vault
git status
git pull
git push
```

**After Migration:**
```bash
# NixOS rebuild to update paths
cd ~/nixos-config
sudo nixos-rebuild switch --flake .#acer-swift

# Verify Obsidian can find vault
# (if using Obsidian GUI, may need to re-add vault)

# Verify all Justfile commands work
cd ~/knowledge-vault
just sync
just draft test-migration concept
just validate
just stats
```

## Implementation Plan

The implementation will be handled by the `writing-plans` skill, which will create a detailed step-by-step plan with tasks organized by:

1. NixOS configuration updates (obsidian module, mcp module)
2. Skill creation (unified knowledge-vault skill)
3. Skills migration (archive old skills)
4. Justfile enhancements (sync-push command)
5. Migration procedure (move vault, test)
6. Verification (test all workflows)

## Success Criteria

- [ ] Vault moved to `~/knowledge-vault` on all hosts
- [ ] Obsidian MCP removed from NixOS config
- [ ] Unified `knowledge-vault` skill created and working
- [ ] Old vault skills archived in claude-code-skills repo
- [ ] Justfile `sync-push` command added and tested
- [ ] All vault operations auto-sync to remote
- [ ] Obsidian GUI still works (if used)
- [ ] All existing documentation accessible at new location
- [ ] Git workflow works smoothly (pull, commit, push)
- [ ] Skill provides clear error messages and guidance

## Future Enhancements

- Auto-cleanup of old drafts via scheduled job
- Skill integration with project CLAUDE.md files
- Automated sync from project repos to vault (reverse of current sync script)
- Vault statistics dashboard (most edited docs, recent changes)
- Skill-driven graph visualization of vault connections
