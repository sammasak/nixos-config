# System configuration (host profile schema + locale/time/nix settings)
{
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;
  locale = "en_US.UTF-8";
in
{
  imports = [
    ./fleet.nix
    ./power-schedule.nix
    ./systemd-verify.nix
  ];

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
            description = "Becomes networking.hostName; also the key into sam.fleet.hosts and, lowercased, host.name in telemetry.";
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
        };
      };
      default = { };
    };

    # Set from lib/users.nix (flake-modules/nixos-configurations.nix); a field it adds must be declared here.
    userConfig = mkOption {
      type = types.submodule {
        options = {
          git.userName = mkOption {
            type = types.str;
            description = "Git author name, and the GitHub account the unattended coordinator may write to.";
          };
          git.email = mkOption {
            type = types.str;
            description = "Git author email.";
          };
          sshKeys = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "The user's authorized SSH public keys; the deployer's key also admits the deploy user.";
          };
        };
      };
      default = { };
      description = "User identity data: git profile and SSH keys.";
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
    i18n.defaultLocale = locale;
    i18n.extraLocaleSettings = {
      LC_ADDRESS = locale;
      LC_IDENTIFICATION = locale;
      LC_MEASUREMENT = locale;
      LC_MONETARY = locale;
      LC_NAME = locale;
      LC_NUMERIC = locale;
      LC_PAPER = locale;
      LC_TELEPHONE = locale;
      LC_TIME = locale;
    };

    console.keyMap = "sv-latin1";

    # Unfree is opt-in per package, not a blanket allow. `allowUnfree = true`
    # made the predicate below decorative and let any transitive unfree
    # dependency in unannounced. With it false the predicate is the real gate:
    # an unexpected unfree package fails eval, by name, at review time.
    #
    # The list below is complete: every host evaluates with it.
    # Redistributable *firmware* is NOT gated here:
    # hardware.enableRedistributableFirmware goes through nixpkgs' separate
    # `allowUnfreeRedistributableFirmware` knob, so no allowlistedLicenses
    # escape hatch is needed.
    nixpkgs.config.allowUnfree = false;
    nixpkgs.config.allowUnfreePredicate =
      pkg:
      builtins.elem (lib.getName pkg) [
        "antigravity-cli" # Google agent CLI (gemini-cli successor), desktop only
        "claude-code" # Anthropic CLI, all hosts
        "open-webui" # custom licence (nixpkgs marks it unfree), acer only: modules/homelab/open-webui.nix
        "unrar" # unfreeRedistributable, from core/packages.nix
        "nvidia-x11" # asus only: the RTX 3070 driver, hosts/asus-b460m
        # CUDA EULA, asus only: what pkgs.ollama-cuda builds and runs with
        "cccl"
        "cuda_crt"
        "cuda_cudart"
        "cuda_nvcc"
        "cuda_nvrtc"
        "libcublas"
        "libnvvm"
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
