# Obsidian Knowledge Vault Setup Guide

This guide will set up your Obsidian knowledge vault with MCP integration across all hosts.

## What This Sets Up

✅ **Obsidian MCP server** on ALL hosts (desktop + servers)
✅ **Obsidian GUI** on desktop hosts only (Hyprland enabled)
✅ **documentation-to-obsidian skill** for LLM doc writing
✅ **Sync script** to copy docs from repos to vault
✅ **Git-based vault** synced across all hosts

## Step 1: Clone Vault Repository

The vault is a separate GitHub repository that must be cloned:

```bash
# Clone the knowledge vault
gh repo clone sammasak/knowledge-vault ~/Documents/knowledge-vault
```

## Step 2: Deploy NixOS Configuration

On your current host (lenovo-21CB001PMX):

```bash
cd ~/nixos-config
sudo nixos-rebuild switch --flake .#$(hostname)
```

This will:
- Configure Obsidian MCP server in Claude Code (points to ~/Documents/knowledge-vault)
- Install Obsidian GUI (you're on a desktop host)
- Deploy vault-related skills

## Step 3: Sync Documentation from Repos

Run the sync script to copy docs from your project repos:

```bash
# Run sync script
~/Documents/knowledge-vault/Meta/scripts/sync-from-repos.sh

# Review what was synced
cd ~/Documents/knowledge-vault
git status

# Commit synced documentation
git add .
git commit -m "Initial sync: documentation from all project repos"
git push
```

## Step 4: Test MCP Integration

```bash
# Start Claude Code
claude

# Test Obsidian MCP server
```

In Claude Code conversation, try:
```
"List all files in my knowledge vault"
"Read the homelab-gitops project index"
"Search for notes about flake-parts"
```

## Step 5: Test Documentation Writing Skill

```
"Document how the specialisation pattern works in NixOS"
```

Claude should:
1. Use the `documentation-to-obsidian` skill
2. Write to `Concepts/specialisations.md`
3. Use proper frontmatter and wikilinks
4. Connect to related concepts

## Step 6: Deploy to Other Hosts

On each other host (acer-swift, msi-ms7758, servers):

```bash
# Clone vault first
gh repo clone sammasak/knowledge-vault ~/Documents/knowledge-vault

# Then deploy NixOS config (sets up MCP)
cd ~/nixos-config
sudo nixos-rebuild switch --flake .#$(hostname)
```

Now all hosts can query documentation via Claude Code!

## Verification Checklist

After deployment, verify:

- [ ] Vault structure exists: `ls ~/Documents/knowledge-vault/`
- [ ] MCP server configured: `cat ~/.config/claude-code/settings.json | jq '.mcpServers.obsidian'`
- [ ] Skill deployed: `ls ~/.claude/skills/documentation-to-obsidian/`
- [ ] Obsidian GUI launches (desktop hosts only)
- [ ] Claude Code can read vault notes
- [ ] Documentation writing skill works

## Keeping Vault Updated

### On Dev Machine (when docs change)

```bash
# Sync docs from repos
~/Documents/knowledge-vault/Meta/scripts/sync-from-repos.sh

# Commit and push
cd ~/Documents/knowledge-vault
git add . && git commit -m "Sync latest docs" && git push
```

### On Other Hosts

```bash
# Pull updates
cd ~/Documents/knowledge-vault && git pull
```

## Troubleshooting

### MCP server not working

```bash
# Check MCP config
cat ~/.config/claude-code/settings.json | jq '.mcpServers.obsidian'

# Test MCP server manually
npx -y @mauricio.wolff/mcp-obsidian@latest ~/Documents/knowledge-vault
```

### Skill not available

```bash
# Check skill is deployed
ls -la ~/.claude/skills/documentation-to-obsidian/

# Rebuild to deploy skill
sudo nixos-rebuild switch --flake .#$(hostname)
```

### Vault not syncing

```bash
# Check git status
cd ~/Documents/knowledge-vault
git status
git remote -v

# Re-run sync script
~/Documents/knowledge-vault/Meta/scripts/sync-from-repos.sh
```

## Next Steps

Once set up:

1. **Write cross-project concepts** to `Concepts/`
2. **Document technologies** in `Technologies/`
3. **Keep project docs synced** from repos
4. **Use wikilinks** to connect related notes
5. **Query via Claude Code** on any host

## Architecture Summary

```
CLAUDE.md files:
  → Stay in project repos
  → Claude Code reads directly

Obsidian vault:
  → Human-readable documentation only
  → docs/ directories synced from repos
  → Cross-project concepts and guides
  → Synced via git to all hosts
  → Accessible via MCP on all hosts
```

**No repos need to be cloned on most hosts - just the vault!**
