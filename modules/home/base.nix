{pkgs, config, ... }:
{
  home.packages = with pkgs; [
    ripgrep
  ];

  programs.git = {
    enable = true;
    settings = {
      user = {
        name = "sammasak";
        email = "23168291+sammasak@users.noreply.github.com";
      };
      init.defaultBranch = "main";
      pull.rebase = true;
    };
  };

  programs.nushell.enable = true;

  programs.starship = {
    enable = true;
    enableNushellIntegration = true;
  };
}
