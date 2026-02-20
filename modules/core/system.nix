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

          desktop = mkOption {
            type = types.str;
            default = "hyprland";
            description = "Desktop stack identifier.";
          };

          waybarTheme = mkOption {
            type = types.str;
            default = "minimal";
            description = "Waybar theme name.";
          };

          sddmTheme = mkOption {
            type = types.str;
            default = "astronaut";
            description = "SDDM theme name.";
          };

          displayManager = mkOption {
            type = types.str;
            default = "sddm";
            description = "Display manager to use.";
          };

          defaultWallpaper = mkOption {
            type = types.str;
            default = "wallpaper.jpg";
            description = "Default wallpaper asset file name.";
          };

          terminal = mkOption {
            type = types.str;
            default = "kitty";
            description = "Default terminal program id.";
          };

          browser = mkOption {
            type = types.str;
            default = "firefox";
            description = "Default browser program id.";
          };

          editor = mkOption {
            type = types.str;
            default = "vscode";
            description = "Default editor program id.";
          };

          shell = mkOption {
            type = types.str;
            default = "bash";
            description = "User shell package attribute name.";
          };

          tuiFileManager = mkOption {
            type = types.str;
            default = "yazi";
            description = "Default terminal file manager id.";
          };

          videoDriver = mkOption {
            type = types.str;
            default = "intel";
            description = "Video driver module selector.";
          };

          monitors = mkOption {
            type = types.listOf types.str;
            # Hyprland monitor rules are `name,resolution,position,scale`.
            # A leading comma means "all monitors".
            default = [ ",preferred,auto,1" ];
            description = "Hyprland monitor definitions.";
          };

          laptop = mkOption {
            type = types.bool;
            default = false;
            description = "Whether this host is a laptop.";
          };

          games = mkOption {
            type = types.bool;
            default = false;
            description = "Whether gaming extras are enabled.";
          };

          hardwareControl = mkOption {
            type = types.bool;
            default = false;
            description = "Whether hardware control extras (fan/RGB/thermals) are enabled.";
          };

          fancontrol = mkOption {
            type = types.bool;
            default = true;
            description = "Whether to enable software fan control (lm_sensors fancontrol) when a host fancontrol config file exists.";
          };

          hwmonModules = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "Extra hwmon kernel modules to load (for fan/PWM sensors).";
          };

          roles = mkOption {
            type = types.listOf types.str;
            default = [ "base" ];
            description = "Role aspects enabled for this host.";
          };

          sshAuthorizedKeys = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "Optional host-specific SSH authorized key override.";
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

    userConfig = mkOption {
      type = types.attrs;
      default = { };
      description = "User identity data (for example git profile and SSH keys).";
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
        ];
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        warn-dirty = false;
      };
      optimise.automatic = true;
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

    nixpkgs.config.allowUnfree = true;

    environment.variables =
      {
        XDG_CACHE_HOME = "$HOME/.cache";
        XDG_CONFIG_HOME = "$HOME/.config";
        XDG_DATA_HOME = "$HOME/.local/share";
        XDG_BIN_HOME = "$HOME/.local/bin";
        PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
      }
      // lib.optionalAttrs (profile.desktop == "hyprland") {
        # Makes Nixpkgs-wrapped Electron apps prefer Wayland in Wayland sessions.
        NIXOS_OZONE_WL = "1";
      };

    system.stateVersion = "25.11";
  };
}
