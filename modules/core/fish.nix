# Fish shell - friendly interactive shell with native inline suggestions
{ ... }:
{
  programs.fish = {
    enable = true;

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

    interactiveShellInit = ''
      # Disable fish greeting
      set fish_greeting

      # Run neofetch on shell start
      neofetch
    '';
  };

  # Starship prompt (already configured, works with fish)
  programs.starship = {
    enable = true;
    enableFishIntegration = true;
  };

  # fzf fuzzy finder with fish integration
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
