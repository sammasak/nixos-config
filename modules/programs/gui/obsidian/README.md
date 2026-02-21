# Obsidian Knowledge Management

Declarative Obsidian configuration with filesystem-based MCP integration for LLM access.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│ All Hosts (Desktop + Servers)                          │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │ Obsidian MCP Server (claude-code/mcp.nix)      │   │
│  │ - Filesystem-based access                       │   │
│  │ - Works WITHOUT Obsidian app                    │   │
│  │ - Points to ~/knowledge-vault         │   │
│  │ - Available on ALL hosts                        │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │ Vault (Git Repo)                                │   │
│  │ ~/knowledge-vault/                    │   │
│  │   ├── Projects/ (COPIES from repos)            │   │
│  │   │   ├── nixos-config/CLAUDE.md               │   │
│  │   │   ├── homelab-gitops/CLAUDE.md             │   │
│  │   │   ├── workstation-api/CLAUDE.md            │   │
│  │   │   └── project-jarvis/CLAUDE.md             │   │
│  │   ├── Concepts/  (shared knowledge)            │   │
│  │   ├── Technologies/  (tech stack docs)         │   │
│  │   └── Meta/scripts/sync-from-repos.sh          │   │
│  │                                                  │   │
│  │ - Self-contained git repository                │   │
│  │ - Synced across all hosts via git              │   │
│  │ - No repos need to be cloned                   │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│ Desktop Hosts Only (Hyprland Enabled)                  │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │ Obsidian GUI App                                │   │
│  │ - Installed via home-manager                    │   │
│  │ - Read-only config from Nix store               │   │
│  │ - Conditional on isDesktopMode                  │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│ Dev Machine Only (Where Repos Are Cloned)              │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │ Sync Script                                     │   │
│  │ ~/knowledge-vault/Meta/scripts/       │   │
│  │   sync-from-repos.sh                            │   │
│  │                                                  │   │
│  │ Copies CLAUDE.md + docs/ from:                  │   │
│  │   ~/nixos-config/      → vault/Projects/...    │   │
│  │   ~/homelab-gitops/    → vault/Projects/...    │   │
│  │   ~/workstation-api/   → vault/Projects/...    │   │
│  │   ~/project-jarvis/    → vault/Projects/...    │   │
│  │                                                  │   │
│  │ Then: git add, commit, push                     │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

## Key Design Decisions

1. **Vault is Self-Contained Git Repo**: No repo cloning required on all hosts
   - Vault contains human-readable documentation (docs/ from repos)
   - CLAUDE.md files stay in repos (Claude Code reads them directly)
   - Synced via git to all hosts (desktop + servers)
   - Sync script copies docs/ from repos on dev machine, then git push
   - All other hosts just git pull the vault

2. **Filesystem MCP**: MCP server reads Markdown files directly
   - Works on servers without Obsidian GUI
   - No Obsidian plugins required for LLM access
   - Faster and simpler than API-based MCP

3. **Fully Declarative**: Everything managed via NixOS config
   - Vault structure defined in `default.nix`
   - Plugins (when enabled) packaged as Nix derivations
   - MCP configuration in `claude-code/mcp.nix`

## Files

```
modules/programs/gui/obsidian/
├── default.nix           # Main module (vault structure, settings)
└── README.md             # This file

lib/
└── obsidian-plugins.nix  # Plugin packaging helpers

modules/programs/cli/claude-code/
└── mcp.nix               # MCP server configuration (includes obsidian)
```

## Usage

### For LLMs (Claude Code)

```bash
# From ANY host (desktop or server), Claude Code can query vault:
claude

# In conversation:
"What does my nixos-config CLAUDE.md say about desktop specialisation?"
"Find all notes about SOPS encryption"
"Show me the workstation-api architecture"
```

The MCP server provides tools:
- `obsidian_read_note` - Read any note by path
- `obsidian_search` - Search across all notes
- `obsidian_list` - List notes in directory

### For Humans (Desktop Hosts)

On hosts with Hyprland enabled (acer-swift, lenovo-21CB001PMX):

1. Open Obsidian application
2. Vault auto-discovered at `~/knowledge-vault`
3. Browse notes, edit, use graph view
4. All project CLAUDE.md files accessible via `Projects/` folder

## Adding New Repos

1. **Update sync script** (`Meta/scripts/sync-from-repos.sh`):
   ```bash
   REPOS=(
     # ... existing repos ...
     "new-repo:$HOME/new-repo"
   )
   ```

2. **Run sync on dev machine**:
   ```bash
   ~/knowledge-vault/Meta/scripts/sync-from-repos.sh
   cd ~/knowledge-vault
   git add Projects/new-repo/
   git commit -m "Add new-repo documentation"
   git push
   ```

3. **Pull on other hosts**:
   ```bash
   cd ~/knowledge-vault
   git pull
   ```

## Community Plugins (Optional)

Currently disabled (commented out) because SHA256 hashes need to be computed.

To enable:

1. **Find Release URL**:
   ```bash
   # Example for dataview plugin
   https://github.com/blacksmithgu/obsidian-dataview/releases/download/0.5.67/dataview-0.5.67.zip
   ```

2. **Compute SHA256**:
   ```bash
   nix-prefetch-url https://github.com/blacksmithgu/obsidian-dataview/releases/download/0.5.67/dataview-0.5.67.zip
   ```

3. **Update `lib/obsidian-plugins.nix`**:
   ```nix
   dataview = buildObsidianPlugin {
     pname = "dataview";
     version = "0.5.67";
     owner = "blacksmithgu";
     repo = "obsidian-dataview";
     sha256 = "sha256-ABC123...";  # <-- Replace with actual hash
   };
   ```

4. **Uncomment in `default.nix`**:
   ```nix
   communityPlugins = [
     plugins.dataview
     plugins.templater
     plugins.obsidian-git
   ];
   ```

## Initial Setup

### 1. Create Vault Repository (Dev Machine)

```bash
# Build config to create initial vault structure
sudo nixos-rebuild switch --flake .#$(hostname)

# Navigate to vault
cd ~/knowledge-vault

# Initialize git repo
git init
git add .
git commit -m "Initial vault structure from NixOS config"

# Create private GitHub repo and push
git remote add origin git@github.com:sammasak/knowledge-vault-private.git
git push -u origin main
```

### 2. Sync Documentation from Repos (Dev Machine)

```bash
# Run sync script
~/knowledge-vault/Meta/scripts/sync-from-repos.sh

# Review and commit changes
cd ~/knowledge-vault
git status
git add .
git commit -m "Initial sync from project repos"
git push
```

### 3. Clone Vault on Other Hosts

On each other host (servers, laptop, etc.):

```bash
# Build config (creates MCP server)
sudo nixos-rebuild switch --flake .#$(hostname)

# Clone vault
git clone git@github.com:sammasak/knowledge-vault-private.git ~/knowledge-vault
```

Now all hosts have access to all documentation via MCP, without needing to clone any project repos!

### Keeping Vault Updated

**On dev machine (when you update CLAUDE.md files):**
```bash
~/knowledge-vault/Meta/scripts/sync-from-repos.sh
cd ~/knowledge-vault
git add . && git commit -m "Sync latest docs" && git push
```

**On other hosts:**
```bash
cd ~/knowledge-vault && git pull
```

**Optional: Automate with systemd timer** (add to NixOS config):
```nix
systemd.user.services.vault-sync = {
  script = ''
    cd ~/knowledge-vault
    git pull --rebase
  '';
};

systemd.user.timers.vault-sync = {
  wantedBy = [ "timers.target" ];
  timerConfig = {
    OnBootSec = "5m";
    OnUnitActiveSec = "1h";
  };
};
```

## Troubleshooting

### MCP server not working

```bash
# Test MCP server manually
npx -y @mauricio.wolff/mcp-obsidian@latest ~/knowledge-vault

# Check Claude Code MCP config
cat ~/.config/claude-code/settings.json | jq '.mcpServers.obsidian'
```

### Vault not appearing in Obsidian

```bash
# Check vault path
ls ~/knowledge-vault

# Check if vault is git repo
cd ~/knowledge-vault && git status
```

### Documentation out of date

```bash
# On dev machine, re-sync
~/knowledge-vault/Meta/scripts/sync-from-repos.sh

# On other hosts, pull
cd ~/knowledge-vault && git pull
```

## Architecture Benefits

1. **No Repo Cloning Required**: Hosts only need the vault repo, not all project repos
2. **Git-Based Sync**: Simple `git pull` keeps all hosts updated
3. **Self-Contained**: Vault is a standalone git repository
4. **Multi-Host**: MCP works on desktops AND servers
5. **LLM-Native**: Claude Code can query docs on any host
6. **Disaster Recovery**: Everything in git (vault synced separately from repos)
7. **Atomic Updates**: `nixos-rebuild switch` sets up MCP + structure on all hosts

## Related Documentation

- [Model Context Protocol](https://modelcontextprotocol.io)
- [Obsidian MCP Server](https://github.com/bitbonsai/mcp-obsidian)
- [Home Manager Obsidian Module](https://github.com/nix-community/home-manager/blob/master/modules/programs/obsidian.nix)
