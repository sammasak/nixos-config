# Fonts configuration - Additional fonts beyond what Stylix provides
# Stylix handles: JetBrains Mono, Noto Sans/Serif, Noto Color Emoji

{pkgs, ...}:
{
  fonts.packages = with pkgs; [
    # Icon fonts (needed for status bar, launcher icons)
    font-awesome
    material-design-icons
    nerd-fonts.jetbrains-mono
  ];

  # Font rendering tweaks
  fonts.fontconfig = {
    antialias = true;
    hinting = {
      enable = true;
      style = "slight";
    };
    subpixel.rgba = "rgb";
  };
}
