# Verified SSH host public keys (nixos-config#86): the fleet and github.com pinned in /etc/ssh/ssh_known_hosts, so
# no client trusts a server on first use. github.com comes from the publisher's API; each fleet key converts
# (ssh-to-age) to that host's recipient in secrets/.sops.yaml, the key the host decrypts its secrets with, which is
# evidence independent of any ssh connection. Fingerprints beside the keys; docs/ssh-host-keys.md has the rest.
{ config, lib, ... }:
let
  cfg = config.sam.sshKnownHosts;
  # a host reaches itself as localhost too (lenovo's deploy-rs node is a loopback self-push), under its own key only
  self = [ "localhost" "127.0.0.1" "::1" ];
  own = name: names: if config.networking.hostName == name then names ++ self else names;
  hosts = {
    # api.github.com/meta; SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU (also inline in modules/homelab/flux.nix)
    github = {
      hostNames = [ "github.com" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
    };
    # read on the machine, sops recipient age13lj7p...; SHA256:7DLYFLKZ4wrcrO0Bk7MnZ8yYHrVeu5pFsSwYWjvpNGs
    lenovo-21CB001PMX = {
      hostNames = own "lenovo-21CB001PMX" [ "lenovo-21CB001PMX" "192.168.10.154" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ17UFIIh7VzaEykstxZC3QaPDrya+YSS0wMtTAggp4q";
    };
    # sops recipient age1uu9y3...; SHA256:5Ong1jvhk4Hgx82l2fYrKBjqlkVyG5rYvYfVPo7WdRY
    acer-swift = {
      hostNames = own "acer-swift" [ "acer-swift" "192.168.10.110" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF9kicjYJJdW1tP6dG0I/PSh8kse7e6ueStLS9fsNJGT";
    };
    # sops recipient age1g0k9v...; SHA256:JebDBAzSWRc/WHY8wQG7jVcidYFp4eFKyjuTzXl5Jwc
    msi-ms7758 = {
      hostNames = own "msi-ms7758" [ "msi-ms7758" "msi" "192.168.10.235" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN3KB1qWY1sl8s3yJ18FMAFH5XU2UL9DJhnnHsgDryP1";
    };
    # sops recipient age16l5rq...; SHA256:i78xzl+ImmEgGFp0QehlBaa3zuFgkpk2nU5ALIHZMjY
    black-pi = {
      hostNames = own "black-pi" [ "black-pi" "192.168.10.137" "192.168.10.136" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH88AIyzWh38c9+97gSFa87QA02OJL8KCRAATRtyQ7Vo";
    };
    # sops recipient age1kdjql... (the Wi-Fi PSK it joined with); SHA256:auOEtU3d4yfB4U6iB7WIt0gSCLwK7hCDPorJAwVs0sY
    naked-pi = {
      hostNames = own "naked-pi" [ "naked-pi" "192.168.10.127" "192.168.10.138" "192.168.10.180" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMyeESlmIoNX5aWSaXmM/7fvWXN+2tMCI/5no21XXct7";
    };
  };
in
{
  options.sam.sshKnownHosts = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Pin the verified host keys of the fleet and github.com in /etc/ssh/ssh_known_hosts.";
    };
    strict = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Refuse unknown and changed host keys for every ssh client on the host (StrictHostKeyChecking yes); a user's ~/.ssh/config still wins for the hosts it names.";
    };
  };

  config = lib.mkIf cfg.enable {
    programs.ssh.knownHosts = hosts;
    # mkAfter: a per-host exception another module adds to extraConfig stays ahead of this catch-all (ssh keeps the
    # first value); the whole of extraConfig precedes nixpkgs' generated "Host *", and a user's own config precedes both
    programs.ssh.extraConfig = lib.mkIf cfg.strict (lib.mkAfter ''
      Host *
        StrictHostKeyChecking yes
        UpdateHostKeys no
    '');
  };
}
