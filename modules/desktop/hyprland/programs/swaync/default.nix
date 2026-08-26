# SwayNC - Notification Center for Wayland
{ pkgs, config, ... }:
let
  colors = config.lib.stylix.colors.withHashtag;
in
{
  services.swaync = {
    enable = true;

    settings = {
      positionX = "right";
      positionY = "top";
      control-center-height = 600;
      control-center-width = 280;
      notification-window-width = 240;
      notification-icon-size = 20;
      fit-to-screen = false;
      notification-body-image-height = 80;
      notification-body-image-width = 160;
      hide-on-clear = true;
      hide-on-action = true;
      keyboard-shortcuts = true;
      image-visibility = "when-available";
      transition-time = 200;
      widgets = [
        "inhibitors"
        "title"
        "dnd"
        "notifications"
      ];
      widget-config = {
        inhibitors = {
          text = "Inhibitors";
          button-text = "Clear All";
          clear-all-button = true;
        };
        title = {
          text = "Notifications";
          clear-all-button = true;
          button-text = "Clear All";
        };
        dnd = {
          text = "Do Not Disturb";
        };
      };
    };

    style = ''
      * {
        font-family: "JetBrainsMono Nerd Font";
        font-weight: bold;
      }

      .notification-row {
        outline: none;
      }

      .notification-row:focus,
      .notification-row:hover {
        background: rgba(255, 255, 255, 0.1);
      }

      .notification {
        border-radius: 8px;
        margin: 6px 12px;
        box-shadow: 0 0 0 1px rgba(0, 0, 0, 0.3), 0 1px 3px 1px rgba(0, 0, 0, 0.7);
        padding: 0;
      }

      .notification-content {
        background: ${colors.base00};
        padding: 8px;
        border-radius: 8px;
      }

      .close-button {
        background: ${colors.base02};
        color: ${colors.base05};
        text-shadow: none;
        padding: 0;
        border-radius: 100%;
        margin-top: 6px;
        margin-right: 6px;
        box-shadow: none;
        border: none;
        min-width: 24px;
        min-height: 24px;
      }

      .close-button:hover {
        box-shadow: none;
        background: ${colors.base03};
        transition: all 0.15s ease-in-out;
        border: none;
      }

      .notification-default-action,
      .notification-action {
        padding: 4px;
        margin: 0;
        box-shadow: none;
        background: transparent;
        border: none;
        color: ${colors.base05};
      }

      .notification-default-action:hover,
      .notification-action:hover {
        background: rgba(255, 255, 255, 0.1);
      }

      .notification-default-action {
        border-radius: 8px;
      }

      .summary {
        font-size: 11px;
        font-weight: bold;
        background: transparent;
        color: ${colors.base05};
        text-shadow: none;
      }

      .time {
        font-size: 10px;
        font-weight: bold;
        background: transparent;
        color: ${colors.base04};
        text-shadow: none;
        margin-right: 12px;
      }

      .body {
        font-size: 10px;
        font-weight: normal;
        background: transparent;
        color: ${colors.base04};
        text-shadow: none;
      }

      .control-center {
        background: alpha(${colors.base00}, 0.9);
        border-radius: 8px;
        margin: 6px;
        box-shadow: 0 0 0 1px rgba(0, 0, 0, 0.3), 0 1px 3px 1px rgba(0, 0, 0, 0.7);
      }

      .control-center-list {
        background: transparent;
      }

      .control-center-list-placeholder {
        opacity: 0.5;
      }

      .floating-notifications {
        background: transparent;
      }

      .blank-window {
        background: transparent;
      }

      .widget-title {
        margin: 8px;
        font-size: 1.2em;
        color: ${colors.base05};
      }

      .widget-title > button {
        font-size: initial;
        color: ${colors.base05};
        text-shadow: none;
        background: ${colors.base02};
        border: none;
        box-shadow: none;
        border-radius: 8px;
      }

      .widget-title > button:hover {
        background: ${colors.base03};
      }

      .widget-dnd {
        margin: 8px;
        font-size: 1.1em;
        color: ${colors.base05};
      }

      .widget-dnd > switch {
        font-size: initial;
        border-radius: 8px;
        background: ${colors.base02};
        border: none;
        box-shadow: none;
      }

      .widget-dnd > switch:checked {
        background: ${colors.base0D};
      }

      .widget-dnd > switch slider {
        background: ${colors.base05};
        border-radius: 8px;
      }

      .widget-inhibitors {
        margin: 8px;
        font-size: 1em;
        color: ${colors.base05};
      }

      .widget-inhibitors > button {
        font-size: initial;
        color: ${colors.base05};
        text-shadow: none;
        background: ${colors.base02};
        border: none;
        box-shadow: none;
        border-radius: 8px;
      }

      .widget-inhibitors > button:hover {
        background: ${colors.base03};
      }
    '';
  };

  home.packages = with pkgs; [
    libnotify
  ];
}
