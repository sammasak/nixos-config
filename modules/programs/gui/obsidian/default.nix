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

  # Vault content files (use home.file for vault root, not .obsidian/)
  home.file = {
    # Templates
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

    "Documents/knowledge-vault/Meta/templates/concept.md".text = ''
      ---
      type: concept
      tags: []
      related: []
      ---
      # {{title}}

      ## Overview

      ## Related Concepts

      ## References
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

      ## Related
    '';

    # Sync script
    "Documents/knowledge-vault/Meta/scripts/sync-from-repos.sh" = {
      source = ./sync-script.sh;
      executable = true;
    };

    # Home note
    "Documents/knowledge-vault/Home.md".text = ''
      # Knowledge Vault

      ## Projects
      Human-readable documentation from all my projects.

      - [[Projects/nixos-config/index|NixOS Configuration]]
      - [[Projects/homelab-gitops/index|Homelab GitOps]]
      - [[Projects/workstation-api/index|Workstation API]]
      - [[Projects/project-jarvis/index|Project Jarvis]]

      > **Note**: CLAUDE.md files (AI agent instructions) live in the actual repositories.
      > This vault contains human-readable documentation only.

      ## Concepts
      Shared knowledge across projects (flake-parts, SOPS, specialisations, etc.)

      ## Technologies
      Deep dives into tech stack (NixOS, Kubernetes, Rust, Python, etc.)

      ## Meta
      Vault templates and configuration
    '';

    # Folder structure
    "Documents/knowledge-vault/Projects/.gitkeep".text = "";
    "Documents/knowledge-vault/Concepts/.gitkeep".text = "";
    "Documents/knowledge-vault/Technologies/.gitkeep".text = "";

    # README for Projects folder
    "Documents/knowledge-vault/Projects/README.md".text = ''
      # Projects

      This folder contains documentation copied from project repositories.

      ## Sync Strategy

      On a development machine with all repos cloned, run:
      ```bash
      ~/Documents/knowledge-vault/Meta/scripts/sync-from-repos.sh
      ```

      This copies docs/ directories (NOT CLAUDE.md files) from each repo into this vault.

      The vault is then synced via git to all other hosts.
    '';
  };
}
