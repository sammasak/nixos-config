# SwayNC - Notification Center for Wayland
# Based on AlexNabokikh/nix-config

{pkgs, ...}:
{
  services.swaync = {
    enable = true;

    settings = {
      positionX = "right";
      positionY = "top";
      control-center-height = 800;
      control-center-width = 400;
      notification-window-width = 350;
      notification-icon-size = 32;
      fit-to-screen = false;
      notification-body-image-height = 100;
      notification-body-image-width = 200;
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
        background: #24273A;
        padding: 8px;
        border-radius: 8px;
      }

      .close-button {
        background: #363a4f;
        color: #cad3f5;
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
        background: #494d64;
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
        color: #cad3f5;
      }

      .notification-default-action:hover,
      .notification-action:hover {
        background: rgba(255, 255, 255, 0.1);
      }

      .notification-default-action {
        border-radius: 8px;
      }

      .summary {
        font-size: 14px;
        font-weight: bold;
        background: transparent;
        color: #cad3f5;
        text-shadow: none;
      }

      .time {
        font-size: 12px;
        font-weight: bold;
        background: transparent;
        color: #8087a2;
        text-shadow: none;
        margin-right: 18px;
      }

      .body {
        font-size: 13px;
        font-weight: normal;
        background: transparent;
        color: #a5adce;
        text-shadow: none;
      }

      .control-center {
        background: rgba(24, 25, 38, 0.9);
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
        color: #cad3f5;
      }

      .widget-title > button {
        font-size: initial;
        color: #cad3f5;
        text-shadow: none;
        background: #363a4f;
        border: none;
        box-shadow: none;
        border-radius: 8px;
      }

      .widget-title > button:hover {
        background: #494d64;
      }

      .widget-dnd {
        margin: 8px;
        font-size: 1.1em;
        color: #cad3f5;
      }

      .widget-dnd > switch {
        font-size: initial;
        border-radius: 8px;
        background: #363a4f;
        border: none;
        box-shadow: none;
      }

      .widget-dnd > switch:checked {
        background: #8aadf4;
      }

      .widget-dnd > switch slider {
        background: #cad3f5;
        border-radius: 8px;
      }

      .widget-inhibitors {
        margin: 8px;
        font-size: 1em;
        color: #cad3f5;
      }

      .widget-inhibitors > button {
        font-size: initial;
        color: #cad3f5;
        text-shadow: none;
        background: #363a4f;
        border: none;
        box-shadow: none;
        border-radius: 8px;
      }

      .widget-inhibitors > button:hover {
        background: #494d64;
      }
    '';
  };

  home.packages = with pkgs; [
    libnotify
  ];
}
