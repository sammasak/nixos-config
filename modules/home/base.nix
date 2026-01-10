{pkgs, config, ... }:
{
  home.packages = with pkgs; [
    ripgrep
    neofetch
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

  programs.nushell = {
    enable = true;
    configFile.text = ''
      $env.config = {
        show_banner: false
      }
    '';
    extraConfig = ''
      # Run neofetch on interactive shell startup
      if $nu.is-interactive {
        neofetch
      }
    '';
  };

  programs.starship = {
    enable = true;
    enableNushellIntegration = true;
  };
}
