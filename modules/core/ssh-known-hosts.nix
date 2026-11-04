# Verified SSH host public keys (nixos-config#86): the fleet and github.com pinned in /etc/ssh/ssh_known_hosts, so
# no client trusts a server on first use. Each key was read over an already trusted channel or from the publisher's
# API; the fingerprint stands beside it, docs/ssh-host-keys.md has sources, dates and procedures. Host keys only.
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
    # read on the machine; SHA256:7DLYFLKZ4wrcrO0Bk7MnZ8yYHrVeu5pFsSwYWjvpNGs
    lenovo-21CB001PMX = {
      hostNames = own "lenovo-21CB001PMX" [ "lenovo-21CB001PMX" "192.168.10.154" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ17UFIIh7VzaEykstxZC3QaPDrya+YSS0wMtTAggp4q";
    };
    # read over the pinned ssh channel; SHA256:5Ong1jvhk4Hgx82l2fYrKBjqlkVyG5rYvYfVPo7WdRY
    acer-swift = {
      hostNames = own "acer-swift" [ "acer-swift" "192.168.10.110" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF9kicjYJJdW1tP6dG0I/PSh8kse7e6ueStLS9fsNJGT";
    };
    # read over the pinned ssh channel; SHA256:JebDBAzSWRc/WHY8wQG7jVcidYFp4eFKyjuTzXl5Jwc
    msi-ms7758 = {
      hostNames = own "msi-ms7758" [ "msi-ms7758" "msi" "192.168.10.235" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN3KB1qWY1sl8s3yJ18FMAFH5XU2UL9DJhnnHsgDryP1";
    };
    # read over the pinned ssh channel; SHA256:i78xzl+ImmEgGFp0QehlBaa3zuFgkpk2nU5ALIHZMjY
    black-pi = {
      hostNames = own "black-pi" [ "black-pi" "192.168.10.137" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH88AIyzWh38c9+97gSFa87QA02OJL8KCRAATRtyQ7Vo";
    };
    # naked-pi is not pinned until its key is read on the console (docs/ssh-host-keys.md)
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
    # extraConfig lands before the generated "Host *" block, and a user's own config is read before this file, so
    # the owner's per-host exceptions (ephemeral VMs) stay in force while every other target fails closed
    programs.ssh.extraConfig = lib.mkIf cfg.strict ''
      Host *
        StrictHostKeyChecking yes
        UpdateHostKeys no
    '';
  };
}
