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

          # Vault structure (actual directories, content synced via git)
          extraFiles = {
            # Templates
            "Meta/templates/daily.md".text = ''
              ---
              date: {{date}}
              tags: [daily]
              ---
              # {{date}}

              ## Tasks
              - [ ]

              ## Notes
            '';

            "Meta/templates/concept.md".text = ''
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

            "Meta/templates/tech-note.md".text = ''
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

            # Home note
            "Home.md".text = ''
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
            "Projects/.gitkeep".text = "";
            "Concepts/.gitkeep".text = "";
            "Technologies/.gitkeep".text = "";

            # README for Projects folder
            "Projects/README.md".text = ''
              # Projects

              This folder contains documentation copied from project repositories.

              ## Sync Strategy

              On a development machine with all repos cloned, run:
              ```bash
              ~/Documents/knowledge-vault/Meta/scripts/sync-from-repos.sh
              ```

              This copies CLAUDE.md and docs/ from each repo into this vault.

              The vault is then synced via git to all other hosts.
            '';

            # Sync script
            "Meta/scripts/sync-from-repos.sh" = {
              source = ./sync-script.sh;
              executable = true;
            };
          };
        };
      };
    };
  };
