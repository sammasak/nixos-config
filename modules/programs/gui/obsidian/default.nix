{ lib, pkgs, ... }:

{
  # The GUI is desktop-only (home/default.nix gates the import); the MCP server in
  # claude-code/mcp.nix works on every host regardless.
  programs.obsidian = {
    enable = true;
    package = pkgs.obsidian;

    vaults.main = {
      enable = true;
      target = "knowledge";

      settings = {
        app = {
          alwaysUpdateLinks = true;
          showInlineTitle = true;
          attachmentFolderPath = "attachments";
        };

        appearance = {
          baseFontSize = 16;
          nativeMenus = false;
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
      };
    };
  };

  # A real clone, not a Home Manager symlink: the vault must be a writable git
  # repository on every host.
  home.activation.cloneKnowledgeVault = lib.hm.dag.entryAfter ["writeBoundary"] ''
    VAULT_DIR="$HOME/knowledge"
    VAULT_REPO="git@github.com:sammasak/knowledge.git"

    if [ ! -d "$VAULT_DIR" ]; then
      $DRY_RUN_CMD mkdir -p "$(dirname "$VAULT_DIR")"
      export GIT_SSH_COMMAND="${pkgs.openssh}/bin/ssh"
      $DRY_RUN_CMD ${pkgs.git}/bin/git clone "$VAULT_REPO" "$VAULT_DIR"
      unset GIT_SSH_COMMAND
      echo "Cloned knowledge to $VAULT_DIR"
    elif [ ! -d "$VAULT_DIR/.git" ]; then
      echo "Warning: $VAULT_DIR exists but is not a git repository"
      echo "Please backup and remove $VAULT_DIR, then rebuild to clone properly"
    else
      # Clean up old Home Manager symlinks that point to /nix/store
      echo "Cleaning up old Home Manager symlinks in knowledge..."
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
