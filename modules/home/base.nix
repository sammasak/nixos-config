{pkgs, config, ... }:
{
  home.packages = with pkgs; [
    ripgrep
  ];

  programs.git = {
    enable = true;
    userName = "sammasak";
    userEmail = "23168291+sammasak@users.noreply.github.com";
    extraConfig = {
      init.defaultBranch = "main";
      pull.rebase = true;
    };
  };

  programs.nushell.enable = true;

  programs.starship = {
    enable = true;
    enableNushellIntegration = true;
  };

  # Dotfiles (raw configs symlinked to ~/.config/)
  xdg.configFile."nushell/config.nu".source = ../../dotfiles/nushell/config.nu;
  xdg.configFile."nushell/env.nu".source = ../../dotfiles/nushell/env.nu;
  xdg.configFile."starship.toml".source = ../../dotfiles/starship/starship.toml;
}
