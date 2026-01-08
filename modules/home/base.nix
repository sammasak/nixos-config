{pkgs, ... }:
{
  home.packages = with pkgs; [
    git
    ripgrep
    starship
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

  programs.nushell = {
    enable = true;
  };


  programs.starship = {
    enable = true;
    enableNushellIntegration = true;
  };

  xdg.configFile."starship.toml".source = ../../dotfiles/starship/starship.toml;
}
