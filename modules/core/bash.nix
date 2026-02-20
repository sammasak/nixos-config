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
      neofetch
    '';
  };

  # Atuin - magical shell history with inline suggestions
  # Like nushell's built-in autosuggestions
  programs.atuin = {
    enable = true;
    enableBashIntegration = true;

    settings = {
      # Inline suggestions as you type (like nushell!)
      inline_height = 12;
      show_preview = true;

      # Search behavior
      search_mode = "fuzzy";
      filter_mode_shell_up_key_binding = "directory";

      # UI
      style = "compact";

      # Don't sync to cloud (keep history local)
      auto_sync = false;
      sync_address = "";

      # Keybindings (Ctrl+R for search, up arrow handled by atuin)
      keymap_mode = "auto";
    };
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
