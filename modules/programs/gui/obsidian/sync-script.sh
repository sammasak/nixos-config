#!/usr/bin/env bash
# Sync documentation from project repos into Obsidian vault
# Run this on a dev machine where all repos are cloned

set -euo pipefail

VAULT_ROOT="${VAULT_ROOT:-$HOME/Documents/knowledge-vault}"
PROJECTS_DIR="$VAULT_ROOT/Projects"

# Repository locations (customize per host)
REPOS=(
  "nixos-config:$HOME/nixos-config"
  "homelab-gitops:$HOME/homelab-gitops"
  "workstation-api:$HOME/workstation-api"
  "project-jarvis:$HOME/project-jarvis"
  "claude-code-skills:$HOME/claude-code-skills"
)

echo "Syncing documentation to vault at: $VAULT_ROOT"
echo

for repo in "${REPOS[@]}"; do
  IFS=':' read -r name path <<< "$repo"
  dest="$PROJECTS_DIR/$name"

  echo "Processing $name..."

  # Skip if repo doesn't exist
  if [[ ! -d "$path" ]]; then
    echo "  ⚠️  Repo not found at $path (skipping)"
    continue
  fi

  # Create project directory in vault
  mkdir -p "$dest"

  # Copy README.md if exists
  if [[ -f "$path/README.md" ]]; then
    cp "$path/README.md" "$dest/README.md"
    echo "  ✓ Copied README.md"
  fi

  # Copy docs/ directory if exists (this is the main content)
  if [[ -d "$path/docs" ]]; then
    rsync -av --delete "$path/docs/" "$dest/docs/"
    echo "  ✓ Synced docs/ directory"
  fi

  # Create project index
  cat > "$dest/index.md" <<EOF
---
type: project-index
repo: $path
synced: $(date -I)
---

# $name

**Repository:** \`$path\`
**Last synced:** $(date)

## Documentation

$([ -f "$path/README.md" ] && echo "- [[README|README]]")
$([ -d "$path/docs" ] && echo "- [[docs/|Documentation]]")

## Repository Links

- [GitHub Repository](https://github.com/sammasak/$name)
- [Local Repository]($path)

## Notes

> **CLAUDE.md**: AI agent instructions live in the repository at \`$path/CLAUDE.md\`.
> Claude Code reads them directly from the repo, not from this vault.
EOF

  echo "  ✓ Created project index"
  echo
done

echo "✅ Sync complete!"
echo
echo "Next steps:"
echo "  1. Review changes: cd $VAULT_ROOT && git status"
echo "  2. Commit changes: git add . && git commit -m 'Sync from repos'"
echo "  3. Push to remote: git push"
