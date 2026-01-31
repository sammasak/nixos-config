# Flux GitOps bootstrap module
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.homelab.flux;
in
{
  options.homelab.flux = {
    enable = mkEnableOption "Flux GitOps bootstrap";

    gitUrl = mkOption {
      type = types.str;
      default = "ssh://git@github.com/sammasak/homelab-gitops";
      description = "Git repository URL for Flux";
    };

    gitBranch = mkOption {
      type = types.str;
      default = "main";
      description = "Git branch to track";
    };

    gitPath = mkOption {
      type = types.str;
      default = "clusters/homelab";
      description = "Path within the repo for this cluster";
    };
  };

  config = mkIf cfg.enable {
    # Bootstrap Flux after k3s is ready
    systemd.services.flux-bootstrap = {
      description = "Bootstrap Flux GitOps";
      after = [ "k3s.service" ];
      requires = [ "k3s.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = "30s";
      };

      path = with pkgs; [ kubectl fluxcd coreutils gnugrep ];

      script = ''
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

        # Wait for k3s API to be ready
        echo "Waiting for k3s API..."
        until kubectl get nodes &>/dev/null; do
          sleep 5
        done
        echo "k3s API is ready"

        # Create flux-system namespace
        kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -

        # Create GitHub deploy key secret
        if [ -f /run/secrets/flux-deploy-key ]; then
          kubectl create secret generic flux-system \
            --namespace=flux-system \
            --from-file=identity=/run/secrets/flux-deploy-key \
            --from-literal=known_hosts="github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl" \
            --dry-run=client -o yaml | kubectl apply -f -
          echo "Created flux-system secret"
        else
          echo "Warning: /run/secrets/flux-deploy-key not found, skipping secret creation"
        fi

        # Create SOPS age key secret for decryption
        if [ -f /run/secrets/flux-age-key ]; then
          kubectl create secret generic sops-age \
            --namespace=flux-system \
            --from-file=age.agekey=/run/secrets/flux-age-key \
            --dry-run=client -o yaml | kubectl apply -f -
          echo "Created sops-age secret"
        else
          echo "Warning: /run/secrets/flux-age-key not found, skipping secret creation"
        fi

        # Check if Flux is already bootstrapped
        if kubectl get gitrepository flux-system -n flux-system &>/dev/null; then
          echo "Flux already bootstrapped, skipping"
          exit 0
        fi

        # Bootstrap Flux
        echo "Bootstrapping Flux..."
        flux bootstrap git \
          --url="${cfg.gitUrl}" \
          --branch="${cfg.gitBranch}" \
          --path="${cfg.gitPath}" \
          --private-key-file=/run/secrets/flux-deploy-key \
          --silent

        echo "Flux bootstrap complete"
      '';
    };
  };
}
