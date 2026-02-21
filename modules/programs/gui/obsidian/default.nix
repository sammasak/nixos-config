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

  # Vault content files (use home.file for vault root, not .obsidian/)
  home.file = {
    # Templates - Existing
    "knowledge-vault/Meta/templates/daily.md".text = ''
      ---
      date: {{date}}
      tags: [daily]
      ---
      # {{date}}

      ## Tasks
      - [ ]

      ## Notes
    '';

    "knowledge-vault/Meta/templates/tech-note.md".text = ''
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

    # Templates - New domain-driven
    "knowledge-vault/Meta/templates/concept.md".text = ''
      ---
      type: concept
      domain: # Infrastructure | Homelab | Development
      tags: []
      related: []
      ---
      # {{title}}

      ## Overview

      ## Key Points

      ## Related Concepts

      ## References
    '';

    "knowledge-vault/Meta/templates/architecture.md".text = ''
      ---
      type: architecture
      domain: # Infrastructure | Homelab | Development
      tags: []
      status: # draft | active | deprecated
      ---
      # {{title}}

      ## Context

      ## Components

      ## Data Flow

      ## Decisions

      ## References
    '';

    "knowledge-vault/Meta/templates/runbook.md".text = ''
      ---
      type: runbook
      domain: # Infrastructure | Homelab | Development
      tags: []
      ---
      # {{title}}

      ## Purpose

      ## Prerequisites

      ## Steps

      ## Verification

      ## Rollback

      ## References
    '';

    "knowledge-vault/Meta/templates/plan.md".text = ''
      ---
      type: plan
      domain: # Infrastructure | Homelab | Development
      tags: []
      status: # planning | in-progress | completed | cancelled
      started: {{date}}
      ---
      # {{title}}

      ## Objectives

      ## Context

      ## Tasks

      ## Timeline

      ## Success Criteria

      ## Notes
    '';

    "knowledge-vault/Meta/templates/decision.md".text = ''
      ---
      type: decision
      domain: # Infrastructure | Homelab | Development
      tags: []
      status: # proposed | accepted | rejected | superseded
      date: {{date}}
      ---
      # {{title}}

      ## Context

      ## Decision

      ## Rationale

      ## Consequences

      ## Alternatives Considered

      ## References
    '';

    # Sync script
    "knowledge-vault/Meta/scripts/sync-from-repos.sh" = {
      source = ./sync-script.sh;
      executable = true;
    };

    # Home note
    "knowledge-vault/Home.md".text = ''
      # Knowledge Vault

      ## Domains

      - [[Infrastructure/index|Infrastructure]] - Core platform and foundational services
      - [[Homelab/index|Homelab]] - Personal infrastructure and automation
      - [[Development/index|Development]] - Software projects and workflows

      ## Working Areas

      - [[Drafts/index|Drafts]] - Work in progress documentation
      - [[Archive/index|Archive]] - Historical documentation

      ## Legacy Projects
      Human-readable documentation from all my projects.

      - [[Projects/nixos-config/index|NixOS Configuration]]
      - [[Projects/homelab-gitops/index|Homelab GitOps]]
      - [[Projects/workstation-api/index|Workstation API]]
      - [[Projects/project-jarvis/index|Project Jarvis]]

      > **Note**: CLAUDE.md files (AI agent instructions) live in the actual repositories.
      > This vault contains human-readable documentation only.

      ## Legacy Areas

      - [[Concepts/index|Concepts]] - Shared knowledge across projects
      - [[Technologies/index|Technologies]] - Deep dives into tech stack

      ## Meta
      Vault templates and configuration
    '';

    # Domain structure - Infrastructure
    "knowledge-vault/Infrastructure/.gitkeep".text = "";
    "knowledge-vault/Infrastructure/Concepts/.gitkeep".text = "";
    "knowledge-vault/Infrastructure/Architecture/.gitkeep".text = "";
    "knowledge-vault/Infrastructure/Runbooks/.gitkeep".text = "";
    "knowledge-vault/Infrastructure/Projects/.gitkeep".text = "";

    # Domain structure - Homelab
    "knowledge-vault/Homelab/.gitkeep".text = "";
    "knowledge-vault/Homelab/Concepts/.gitkeep".text = "";
    "knowledge-vault/Homelab/Architecture/.gitkeep".text = "";
    "knowledge-vault/Homelab/Runbooks/.gitkeep".text = "";
    "knowledge-vault/Homelab/Projects/.gitkeep".text = "";

    # Domain structure - Development
    "knowledge-vault/Development/.gitkeep".text = "";
    "knowledge-vault/Development/Concepts/.gitkeep".text = "";
    "knowledge-vault/Development/Workflows/.gitkeep".text = "";
    "knowledge-vault/Development/Projects/.gitkeep".text = "";

    # Working areas
    "knowledge-vault/Drafts/.gitkeep".text = "";
    "knowledge-vault/Drafts/orphaned/.gitkeep".text = "";
    "knowledge-vault/Archive/.gitkeep".text = "";
    "knowledge-vault/Archive/2026/.gitkeep".text = "";

    # Legacy folder structure
    "knowledge-vault/Projects/.gitkeep".text = "";
    "knowledge-vault/Concepts/.gitkeep".text = "";
    "knowledge-vault/Technologies/.gitkeep".text = "";

    # README for Projects folder
    "knowledge-vault/Projects/README.md".text = ''
      # Projects

      This folder contains documentation copied from project repositories.

      ## Sync Strategy

      On a development machine with all repos cloned, run:
      ```bash
      ~/knowledge-vault/Meta/scripts/sync-from-repos.sh
      ```

      This copies docs/ directories (NOT CLAUDE.md files) from each repo into this vault.

      The vault is then synced via git to all other hosts.
    '';
  };
}
