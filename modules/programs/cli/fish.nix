{ ... }:
{
  programs.fish = {
    enable = true;

    shellAliases = {
      gco = "git checkout";
    };

    interactiveShellInit = ''
      # Disable fish greeting
      set fish_greeting

      # Run fastfetch on shell start
      fastfetch
    '';
  };

  programs.starship = {
    enable = true;
    enableFishIntegration = true;
  };

  programs.fzf = {
    enable = true;
    enableFishIntegration = true;

    defaultCommand = "fd --type f --hidden --follow --exclude .git";
    defaultOptions = [
      "--height 40%"
      "--layout=reverse"
      "--border"
      "--inline-info"
    ];
  };
}
