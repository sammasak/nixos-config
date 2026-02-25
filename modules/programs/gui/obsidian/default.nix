{ config, lib, pkgs, ... }:

let
  cfg = config.programs.obsidian;
  plugins = import ../../../../lib/obsidian-plugins.nix { inherit pkgs lib; };
in
{
  # Obsidian GUI enabled only on desktop (import is conditional in home/default.nix)
  # MCP server works on all hosts regardless (configured in claude-code/mcp.nix)
  programs.obsidian = {
    enable = true;
    package = pkgs.obsidian;

    vaults.main = {
      enable = true;
      target = "knowledge-vault";

      settings = {
        app = {
          alwaysUpdateLinks = true;
          showInlineTitle = true;
          attachmentFolderPath = "attachments";
        };

        appearance = {
          baseFontSize = 16;
          nativeMenus = false;
          # Will use Stylix theme colors via Catppuccin
        };

        corePlugins = [
          "backlink"
          "bookmarks"
          "command-palette"
          "daily-notes"
          "file-explorer"
          "global-search"
          "graph"
          "outgoing-link"
          "outline"
          "page-preview"
          "switcher"
          "tag-pane"
          "templates"
        ];

        # Community plugins (optional - uncomment when hashes are updated)
        # communityPlugins = [
        #   plugins.dataview
        #   plugins.templater
        #   plugins.obsidian-git
        # ];
      };
    };
  };

  # Clone knowledge-vault repository if it doesn't exist
  # This ensures all hosts have a proper git repository, not symlinked files
  home.activation.cloneKnowledgeVault = lib.hm.dag.entryAfter ["writeBoundary"] ''
    VAULT_DIR="$HOME/knowledge-vault"
    VAULT_REPO="git@github.com:sammasak/knowledge-vault.git"

    if [ ! -d "$VAULT_DIR" ]; then
      $DRY_RUN_CMD mkdir -p "$(dirname "$VAULT_DIR")"
      $DRY_RUN_CMD ${pkgs.git}/bin/git clone "$VAULT_REPO" "$VAULT_DIR"
      echo "Cloned knowledge-vault to $VAULT_DIR"
    elif [ ! -d "$VAULT_DIR/.git" ]; then
      echo "Warning: $VAULT_DIR exists but is not a git repository"
      echo "Please backup and remove $VAULT_DIR, then rebuild to clone properly"
    else
      # Clean up old Home Manager symlinks that point to /nix/store
      echo "Cleaning up old Home Manager symlinks in knowledge-vault..."
      $DRY_RUN_CMD ${pkgs.findutils}/bin/find "$VAULT_DIR" -type l | while read -r link; do
        if ${pkgs.coreutils}/bin/readlink "$link" | ${pkgs.gnugrep}/bin/grep -q "^/nix/store"; then
          $DRY_RUN_CMD rm "$link"
          echo "Removed symlink: $link"
        fi
      done
      echo "Knowledge vault ready at $VAULT_DIR"
    fi
  '';
}
