# Bash baseline — aliases and interactive startup (home-manager module)
{ ... }:
{
  programs.bash = {
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
    initExtra = ''
      neofetch
    '';
  };
}
