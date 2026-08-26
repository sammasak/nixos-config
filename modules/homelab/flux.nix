# Flux GitOps bootstrap module
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption types;
  cfg = config.homelab.flux;

  # Referenced through the sops option rather than by literal path; ./sops.nix
  # is imported below and homelab.secrets is turned on in the config block, so
  # both secrets are declared in the same evaluation.
  deployKey = config.sops.secrets."flux/deploy_key".path;
  ageKey = config.sops.secrets."flux/age_key".path;
in
{
  imports = [ ./sops.nix ];

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
    # Declares the flux/deploy_key and flux/age_key secrets used below.
    homelab.secrets.enable = true;

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
        if [ -f ${deployKey} ]; then
          kubectl create secret generic flux-system \
            --namespace=flux-system \
            --from-file=identity=${deployKey} \
            --from-literal=known_hosts="github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl" \
            --dry-run=client -o yaml | kubectl apply -f -
          echo "Created flux-system secret"
        else
          echo "Warning: ${deployKey} not found, skipping secret creation"
        fi

        # Create SOPS age key secret for decryption
        if [ -f ${ageKey} ]; then
          kubectl create secret generic sops-age \
            --namespace=flux-system \
            --from-file=age.agekey=${ageKey} \
            --dry-run=client -o yaml | kubectl apply -f -
          echo "Created sops-age secret"
        else
          echo "Warning: ${ageKey} not found, skipping secret creation"
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
          --private-key-file=${deployKey} \
          --silent

        echo "Flux bootstrap complete"
      '';
    };
  };
}
