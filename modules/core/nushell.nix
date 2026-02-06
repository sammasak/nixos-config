# Nushell - Modern shell (home-manager module)
{ ... }:
{
  programs.nushell = {
    enable = true;
    configFile.text = ''
      $env.config = {
        show_banner: false
      }
    '';
    extraConfig = ''
      # Shell aliases
      alias gco = git checkout
      alias k = kubectl
      alias kg = kubectl get
      alias kd = kubectl describe
      alias ka = kubectl apply -f
      alias kdel = kubectl delete
      alias kgp = kubectl get pods
      alias kgs = kubectl get svc
      alias kgd = kubectl get deploy
      alias kgn = kubectl get nodes
      alias kga = kubectl get all

      # Run neofetch on interactive shell startup
      if $nu.is-interactive {
        neofetch
      }
    '';
  };
}
