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
      target = "Documents/knowledge-vault";

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

  # Note: knowledge-vault is a separate git repository
  # Clone it manually: gh repo clone sammasak/knowledge-vault ~/Documents/knowledge-vault
  # Do NOT manage vault content via home-manager - it's managed via git
}
