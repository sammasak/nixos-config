# System configuration (host profile schema + locale/time/nix settings)
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption types;
  profile = config.sam.profile;
in
{
  imports = [ ./fleet.nix ];

  options.sam = {
    profile = mkOption {
      description = "Host profile values used by reusable modules.";
      type = types.submodule {
        options = {
          username = mkOption {
            type = types.enum (builtins.attrNames (import ../../lib/users.nix));
            description = "Primary user for this host: a user in lib/users.nix.";
          };

          hostname = mkOption {
            type = types.str;
            description = "System hostname.";
          };

          devTools = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Whether to ship the interactive developer toolset (claude-code,
              codex, nvim + language toolchains, nodejs/chromium for Playwright,
              herdr, pi-harness). False for appliance-style nodes that are only
              ever administered over SSH.
            '';
          };

          pi = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Opt into the Pi coding agent (docs/pi.md): Home Manager config,
              provider-key exports and the router/free extension. The host
              also declares the sops secrets the keys come from.
            '';
          };

          nativeOtel = mkOption {
            type = types.bool;
            default = false;
            description = "Enable private, collector-sanitized native harness telemetry on this host.";
          };

          roles = mkOption {
            type = types.uniq (types.listOf types.str);
            description = "Role aspects enabled for this host. Set from flake-modules/hosts.nix; a second definition is an error.";
          };

          lanCidr = mkOption {
            type = types.str;
            default = "192.168.10.0/24";
            description = "Trusted LAN CIDR for host-level firewall rules.";
          };
        };
      };
      default = { };
    };

    herdr.machines = mkOption {
      type = types.listOf (types.submodule {
        options = {
          label = mkOption { type = types.strMatching "[A-Za-z0-9_][A-Za-z0-9_.-]*"; description = "Herdr machine label, as in `herdr --machine <label>`."; };
          target = mkOption { type = types.strMatching "([A-Za-z0-9_.-]+@)?[A-Za-z0-9_.-]+"; description = "SSH target `[user@]host` behind the label; the user's own key and known_hosts entry must already work."; };
        };
      });
      default = [ ];
      description = ''
        Herdr saved machines this host should know: each is added with
        `herdr machine add <target> --label <label> --remote-session default`
        at Home Manager activation when the label is not saved yet (a saved
        label is left as herdr has it, even if the target here changed). Only
        the coordinator host declares its workers; a worker declares nothing
        and so sees its own agents only (docs/herdr.md).
      '';
    };

    herdr.worker = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          This host runs unattended Claude Code workers started through Herdr
          (skills `coord:spawn`, or `claude-worker` here): they start with
          `--dangerously-skip-permissions` and Claude Code's settings skip its
          acknowledgment dialog (`skipDangerousModePermissionPrompt`), and a
          message the safeguards flag switches models instead of stopping at a
          dialog (`switchModelsOnFlag`, which the Herdr launcher also hands to a
          bypass-mode `claude` on any host). Plain
          `claude` and the unattended Coordinator are unchanged, and a host
          running `coordinatorWakeup` cannot be a worker host.
        '';
      };
    };

    herdr.trustedDirs = mkOption {
      type = types.listOf (types.strMatching "/[A-Za-z0-9_./-]*");
      default = [ ];
      example = [ "/home/lukas/nixos-config" "/home/lukas/.cache/wt" ];
      description = "Directories whose Claude Code trust dialog is pre-accepted in `~/.claude.json`, besides the `$HOME` every host trusts; the trust covers their subdirectories too.";
    };

    herdr.coordinatorWakeup = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Run `coord:changed` on a user timer and start one spend-capped headless Coordinator session only when it prints an actionable change.";
      };
      interval = mkOption {
        type = types.str;
        default = "2min";
        description = "Pause between two `coord:changed` runs (systemd `OnUnitInactiveSec`); one run costs about 0.6 s and 80 MB.";
      };
      maxBudgetUsd = mkOption {
        type = types.strMatching "[0-9]+([.][0-9]+)?";
        default = "1.00";
        description = "Spend cap for one wake-up session (`claude --max-budget-usd`).";
      };
      # The skills options the owner sets for this host; the wake-up timer and its wrappers pass them to
      # devenv as fixed --option flags (the unattended session itself may pass none).
      mayApprove = mkOption {
        type = types.bool;
        default = false;
        description = "Owner delegation (skills `coordinator.mayApprove`): the Coordinator may add the authorizing label to the owner's own issues; needs `approvalDecision`.";
      };
      approvalDecision = mkOption {
        type = types.nullOr (types.strMatching "https://github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/[1-9][0-9]*#issuecomment-[1-9][0-9]*");
        default = null;
        description = "URL of the issue comment quoting the owner's decision that `mayApprove` rests on (skills `coordinator.approvalDecision`).";
      };
      panes = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "lenovo-21CB001PMX/wM:p1" ];
        description = "The Coordinator's own panes as host/agent_id (skills `coordinator.panes`): never workers for the idle wake, never handoff targets.";
      };
      interactiveQuietSeconds = mkOption {
        type = types.nullOr types.ints.unsigned;
        default = null;
        example = 600;
        description = "Skills `coordinator.interactiveQuietSeconds`: no wake session while a Coordinator pane (`panes`) works or worked within this many seconds, so the timer never races the owner's session; null passes nothing (the skills default, off). Needs a skills pin that declares the option.";
      };
    };

    claude.bulkReader = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Register the skills input's shunt PreToolUse hooks in Claude Code: a
          whole-file Read, or a cat/head/tail of a file, estimated over `minTokens`
          tokens (source code and instruction files excepted) is redirected once to the bulk-reader skill (`scripts/bulk-read.sh`, a
          headless `claude -p` summary). Registers nothing while the skills pin
          lacks the hooks. A developer environment's guest does not inherit it
          from its host (CLAUDE.md, Claude Code, Bulk reader).
        '';
      };
      spillOutput = mkOption {
        type = types.bool;
        default = true;
        description = "With `enable`: also register the PostToolUse hook that saves a successful Bash output over 12000 chars to a log under ~/.cache/claude-spill and hands the session a head and tail excerpt with the path.";
      };
      minTokens = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        description = "`SHUNT_MIN_TOKENS`, the estimated token count a read must exceed to be redirected; null leaves the skills default (8000).";
      };
      model = mkOption {
        type = types.nullOr (types.strMatching "[A-Za-z0-9._-]+");
        default = null;
        description = "`SHUNT_MODEL`, the model bulk-read.sh asks; null leaves the skills default (haiku).";
      };
    };

    claude.telemetry = {
      enable = mkOption {
        type = types.bool;
        default = profile.nativeOtel;
        defaultText = lib.literalExpression "config.sam.profile.nativeOtel";
        description = ''
          Claude Code exports OTLP metrics and events (no prompt or tool content) to
          the local native-otel-relay at 127.0.0.1:4319, which adds the gateway token,
          and registers the skills input's emit-work-ref.sh hook once the pin carries it.
          A developer environment gets it from `sam.workers.instances.<name>.telemetry`,
          never from its host (docs/native-otel-canary.md); there it also turns on
          Codex's metrics exporter and wrapper.
        '';
      };
      resourceAttributes = mkOption {
        type = types.attrsOf (types.strMatching "[A-Za-z0-9._-]+");
        default = { "host.name" = lib.toLower profile.hostname; };
        defaultText = lib.literalExpression ''{ "host.name" = lib.toLower config.sam.profile.hostname; }'';
        description = "`OTEL_RESOURCE_ATTRIBUTES` of the export, also `HARNESS_RESOURCE_ATTRIBUTES` for the hook.";
      };
    };

    # Not under sam.profile: a developer environment's guest copies its host's profile (modules/workers).
    cliTools.factum.enable = mkOption {
      type = types.bool;
      default = false;
      description = "Install factum for the user (Home Manager).";
    };
    cliTools.nixAudit.enable = mkOption {
      type = types.bool;
      default = false;
      description = "Install nix-audit, grype and vulnix for the user (Home Manager; docs/nix-audit-pilot.md).";
    };

    userConfig = mkOption {
      type = types.attrs;
      default = { };
      description = "User identity data (for example git profile and SSH keys).";
    };

    # The single "is this a GUI desktop?" signal. Modules used to probe
    # `programs.hyprland.enable`, which silently tied every desktop gate to one
    # compositor — a second compositor (niri) would have evaluated as headless.
    desktop.enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether this configuration runs a GUI desktop session. Set by
        `modules/specialisations/desktop.nix`; false (the default) means
        headless. Modules must key desktop-only packages, fonts, services and
        Home Manager imports off this option rather than off a compositor's
        own enable flag.
      '';
    };
  };

  config = {
    assertions = [{
      assertion = lib.length (lib.unique (map (m: m.label) config.sam.herdr.machines)) == lib.length config.sam.herdr.machines;
      message = "sam.herdr.machines labels must be unique (herdr --machine addresses a machine by its label).";
    } {
      # the unattended Coordinator stays on dontAsk: it must never share a settings.json that skips the bypass dialog
      assertion = !(config.sam.herdr.worker.enable && config.sam.herdr.coordinatorWakeup.enable);
      message = "sam.herdr.worker and sam.herdr.coordinatorWakeup cannot both be enabled on one host (the Coordinator must not inherit worker permissions).";
    }];

    programs = {
      nix-ld.enable = true;
      nix-ld.libraries = with pkgs; [
        glib
        nss
        nspr
        atk
        cups
        dbus
        expat
        libdrm
        libxkbcommon
        pango
        cairo
        alsa-lib
        at-spi2-atk
        at-spi2-core
        libx11
        libxcomposite
        libxdamage
        libxext
        libxfixes
        libxrandr
        libxcb
        mesa
      ];
      gnupg.agent = {
        enable = true;
        enableSSHSupport = true;
      };
      git.enable = true;
    };

    services.xserver = {
      enable = lib.mkDefault false;
      xkb = {
        layout = "se";
        variant = "";
      };
    };

    nix = {
      settings = {
        auto-optimise-store = true;
        # NixOS adds cache.nixos.org and its key itself
        substituters = [ "https://nix-community.cachix.org" ];
        trusted-public-keys = [
          "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
          # Signs deploy-rs closures pushed from lenovo, so acer's
          # trusted-users = [ "root" ] can accept them from the lukas SSH user.
          "nixos-config-1:Sa0eAfaaRE81zrZZmMboe41QRpPdZoakOfKgAagmSlg="
        ];
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        warn-dirty = false;
      };
    };

    time.timeZone = "Europe/Stockholm";
    i18n.defaultLocale = "en_US.UTF-8";
    i18n.extraLocaleSettings = {
      LC_ADDRESS = "en_US.UTF-8";
      LC_IDENTIFICATION = "en_US.UTF-8";
      LC_MEASUREMENT = "en_US.UTF-8";
      LC_MONETARY = "en_US.UTF-8";
      LC_NAME = "en_US.UTF-8";
      LC_NUMERIC = "en_US.UTF-8";
      LC_PAPER = "en_US.UTF-8";
      LC_TELEPHONE = "en_US.UTF-8";
      LC_TIME = "en_US.UTF-8";
    };

    console.keyMap = "sv-latin1";

    # Unfree is opt-in per package, not a blanket allow. `allowUnfree = true`
    # made the predicate below decorative and let any transitive unfree
    # dependency in unannounced. With it false the predicate is the real gate:
    # an unexpected unfree package fails eval, by name, at review time.
    #
    # The list below is complete: all five hosts evaluate with it.
    # Redistributable *firmware* is NOT gated here:
    # hardware.enableRedistributableFirmware goes through nixpkgs' separate
    # `allowUnfreeRedistributableFirmware` knob, so no allowlistedLicenses
    # escape hatch is needed.
    nixpkgs.config.allowUnfree = false;
    nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
      "antigravity-cli" # Google agent CLI (gemini-cli successor), desktop only
      "claude-code" # Anthropic CLI, all hosts
      "unrar"       # unfreeRedistributable, from core/packages.nix
    ];

    environment.variables = {
      XDG_CACHE_HOME = "$HOME/.cache";
      XDG_CONFIG_HOME = "$HOME/.config";
      XDG_DATA_HOME = "$HOME/.local/share";
      XDG_BIN_HOME = "$HOME/.local/bin";
      # Makes Nixpkgs-wrapped Electron apps prefer Wayland in Wayland sessions.
      NIXOS_OZONE_WL = "1";
    };

    system.stateVersion = "25.11";
  };
}
