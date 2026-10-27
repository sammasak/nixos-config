{
  services.awww.enable = true;

  xdg.configFile = {
    "hypr/scripts/screenshot.sh" = {
      source = ./screenshot.sh;
      executable = true;
    };
    "hypr/scripts/screen-record.sh" = {
      source = ./screen-record.sh;
      executable = true;
    };
    "hypr/scripts/ClipManager.sh" = {
      source = ./ClipManager.sh;
      executable = true;
    };
    "hypr/scripts/wallpaper-select.sh" = {
      source = ./wallpaper-select.sh;
      executable = true;
    };
  };
}
