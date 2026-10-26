# System configuration (host profile schema + locale/time/nix settings)
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption types;
  profile = config.sam.profile;
in
{
  options.sam = {
    profile = mkOption {
      description = "Host profile values used by reusable modules.";
      type = types.submodule {
        options = {
          username = mkOption {
            type = types.str;
            description = "Primary user for this host.";
          };

          hostname = mkOption {
            type = types.str;
            description = "System hostname.";
          };

          timezone = mkOption {
            type = types.str;
            default = "UTC";
            description = "Time zone.";
          };

          locale = mkOption {
            type = types.str;
            default = "en_US.UTF-8";
            description = "Default locale.";
          };

          kbdLayout = mkOption {
            type = types.str;
            default = "us";
            description = "Keyboard layout.";
          };

          kbdVariant = mkOption {
            type = types.str;
            default = "";
            description = "Keyboard layout variant.";
          };

          consoleKeymap = mkOption {
            type = types.str;
            default = "us";
            description = "Virtual console keymap.";
          };

          videoDriver = mkOption {
            type = types.str;
            default = "intel";
            description = "Video driver module selector.";
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

          coordinator = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Opt into the Coordinator agent (docs/coordinator.md): a writable
              checkout of the pinned skills input, its fleet.json, the Claude
              guard hook and the `coordinator` launcher. Needs devTools (Claude
              Code, Herdr); fleet comes from sam.coordinator.fleet.
            '';
          };

          roles = mkOption {
            type = types.listOf types.str;
            default = [ "base" ];
            description = "Role aspects enabled for this host.";
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

    coordinator = {
      identityFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Private key the coordinator host uses for every fleet ssh target
          (IdentitiesOnly), so an owner key sitting in an agent can never be
          offered to a worker and skip the herdr-shim restriction. Required when
          any fleet host has an ssh target.
        '';
      };
      acceptKeys = mkOption {
        type = types.listOf (types.strMatching "^(ssh-|ecdsa-|sk-)[A-Za-z0-9@.:/+=_-]+ [A-Za-z0-9+/=]+( [^\n\"]*)?$");
        default = [ ];
        description = ''
          Public keys of coordinator hosts allowed to reach this worker. Each is
          installed for the primary user with a forced command (herdr-shim) that
          permits only `herdr agent list|get|read|wait|prompt` and the two exact
          session-file reads the coordinator tasks issue (confined to the user's
          Claude and Pi session stores); no shell, no pty, no forwarding. Use a
          dedicated key, never the owner's interactive one.
        '';
      };
      fleet = {
        hosts = mkOption {
          type = types.listOf (types.submodule {
            options = {
              name = mkOption { type = types.strMatching "[A-Za-z0-9_][A-Za-z0-9_:.@/-]*"; description = "Fleet host name as the coordinator reports it."; };
              ssh = mkOption { type = types.nullOr (types.strMatching "([A-Za-z0-9_.-]+@)?[A-Za-z0-9_.-]+"); default = null; description = "SSH target `[user@]host`, or null for the local host."; };
            };
          });
          default = [ ];
          description = "Hosts the Coordinator may inspect over Herdr (read) and message (act, prompted).";
        };
        repos = mkOption {
          type = types.listOf (types.submodule {
            options = {
              name = mkOption { type = types.strMatching "[A-Za-z0-9_][A-Za-z0-9_:.@/-]*"; description = "Repo name as the coordinator reports it."; };
              gh = mkOption { type = types.nullOr (types.strMatching "[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+"); default = null; description = "OWNER/REPO for gh:work, or null."; };
              checkout = mkOption { type = types.nullOr (types.strMatching "/[A-Za-z0-9_./-]*"); default = null; description = "Absolute local checkout for git:recent, or null."; };
            };
          });
          default = [ ];
          description = "Repositories that count as durable evidence for work:status.";
        };
      };
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
    assertions = lib.optionals config.sam.profile.coordinator [
      { assertion = (lib.all (h: h.ssh == null) config.sam.coordinator.fleet.hosts) || config.sam.coordinator.identityFile != null; message = "sam.coordinator.identityFile is required when a fleet host has an ssh target (IdentitiesOnly keeps owner keys away from the herdr-shim)."; }
      { assertion = config.sam.profile.devTools; message = "sam.profile.coordinator needs devTools (claude-code, herdr)."; }
      { assertion = lib.any (h: h.ssh == null) config.sam.coordinator.fleet.hosts; message = "sam.coordinator.fleet.hosts must include the local host (ssh = null)."; }
      { assertion = lib.length (lib.unique (map (h: h.name) config.sam.coordinator.fleet.hosts)) == lib.length config.sam.coordinator.fleet.hosts; message = "sam.coordinator.fleet.hosts has duplicate names."; }
    ];

    # every fleet ssh target is reached with the dedicated key only (system-wide ssh_config, so the user's own
    # ~/.ssh/config stays untouched): ssh would otherwise offer agent keys first and skip the worker's herdr-shim
    programs.ssh.extraConfig = lib.mkIf (config.sam.profile.coordinator && config.sam.coordinator.identityFile != null) (lib.concatMapStrings (h: ''
      Host ${lib.last (lib.splitString "@" h.ssh)}
        IdentityFile ${config.sam.coordinator.identityFile}
        IdentitiesOnly yes
    '') (lib.filter (h: h.ssh != null) config.sam.coordinator.fleet.hosts));

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
        layout = profile.kbdLayout;
        variant = profile.kbdVariant;
      };
    };

    nix = {
      settings = {
        auto-optimise-store = true;
        substituters = [
          "https://cache.nixos.org"
          "https://nix-community.cachix.org"
        ];
        trusted-public-keys = [
          "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
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

    time.timeZone = profile.timezone;
    i18n.defaultLocale = profile.locale;
    i18n.extraLocaleSettings = {
      LC_ADDRESS = profile.locale;
      LC_IDENTIFICATION = profile.locale;
      LC_MEASUREMENT = profile.locale;
      LC_MONETARY = profile.locale;
      LC_NAME = profile.locale;
      LC_NUMERIC = profile.locale;
      LC_PAPER = profile.locale;
      LC_TELEPHONE = profile.locale;
      LC_TIME = profile.locale;
    };

    console.keyMap = profile.consoleKeymap;

    # Unfree is opt-in per package, not a blanket allow. `allowUnfree = true`
    # made the predicate below decorative and let any transitive unfree
    # dependency in unannounced. With it false the predicate is the real gate:
    # an unexpected unfree package fails eval, by name, at review time.
    #
    # The list below is empirically complete — with it, both hosts evaluate to
    # the exact same toplevel derivation as they did under allowUnfree = true.
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
