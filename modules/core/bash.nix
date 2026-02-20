# Bash baseline — aliases and interactive startup (home-manager module)
{ ... }:
{
  programs.bash = {
    enable = true;

    # History configuration
    historySize = 10000;
    historyFileSize = 100000;
    historyControl = [ "ignoredups" "ignorespace" ];

    shellAliases = {
      gco  = "git checkout";
      k    = "kubectl";
      kg   = "kubectl get";
      kd   = "kubectl describe";
      ka   = "kubectl apply -f";
      kdel = "kubectl delete";
      kgp  = "kubectl get pods";
      kgs  = "kubectl get svc";
      kgd  = "kubectl get deploy";
      kgn  = "kubectl get nodes";
      kga  = "kubectl get all";
    };

    initExtra = ''
      # Better history search with arrow keys
      bind '"\e[A": history-search-backward'
      bind '"\e[B": history-search-forward'

      neofetch
    '';
  };

  # fzf fuzzy finder with bash integration
  # Ctrl+R: fuzzy history search
  # Ctrl+T: fuzzy file search
  # Alt+C: fuzzy directory change
  programs.fzf = {
    enable = true;
    enableBashIntegration = true;

    # Theme colors managed by Stylix
    defaultCommand = "fd --type f --hidden --follow --exclude .git";
    defaultOptions = [
      "--height 40%"
      "--layout=reverse"
      "--border"
      "--inline-info"
    ];
  };
}
