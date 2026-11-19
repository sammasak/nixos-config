# Verified SSH host public keys (nixos-config#86): the fleet and github.com pinned in /etc/ssh/ssh_known_hosts, so
# no client trusts a server on first use. github.com comes from the publisher's API; each fleet key converts
# (ssh-to-age) to that host's recipient in secrets/.sops.yaml, the key the host decrypts its secrets with, which is
# evidence independent of any ssh connection. Each host's key, with its fingerprint, is in its own directory
# (hosts/<dir>/ssh_known_hosts); docs/ssh-host-keys.md has the rest.
{ config, lib, ... }:
let
  # a host reaches itself as localhost too (lenovo's deploy-rs node is a loopback self-push), under its own key only
  self = [
    "localhost"
    "127.0.0.1"
    "::1"
  ];
  own = name: names: if config.networking.hostName == name then names ++ self else names;
  addresses =
    name:
    let
      h = config.sam.fleet.hosts.${name};
    in
    lib.optionals (config.sam.fleet.hosts ? ${name}) ([ h.address ] ++ h.extraAddresses);
  # every deploy node's hostName; a host's directory is named after it
  nodes = lib.mapAttrsToList (name: h: h.hostDir or name) deployNodes;
  deployNodes = (import ../../flake-modules/hosts.nix).configurations.nixos;
  file = dir: ../../hosts + "/${dir}/ssh_known_hosts";
  # the one known_hosts line of the file, "<names> ssh-ed25519 <key>"; its sam.fleet addresses are appended here
  pin =
    dir:
    let
      lines = lib.filter (l: l != "" && !lib.hasPrefix "#" l) (
        lib.splitString "\n" (builtins.readFile (file dir))
      );
      line = if builtins.pathExists (file dir) && lib.length lines == 1 then lib.head lines else "";
    in
    builtins.match "([^ ]+) (ssh-ed25519 [A-Za-z0-9+/]+=*)( .*)?" line;
  unpinned = lib.filter (dir: pin dir == null) nodes;
  hosts = {
    # api.github.com/meta; SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU
    github = {
      hostNames = [ "github.com" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
    };
  }
  // lib.genAttrs (lib.subtractLists unpinned nodes) (
    dir:
    let
      m = pin dir;
    in
    {
      hostNames = own dir (lib.splitString "," (lib.elemAt m 0) ++ addresses dir);
      publicKey = lib.elemAt m 1;
    }
  );
  pinned = lib.attrNames (removeAttrs config.programs.ssh.knownHosts [ "github" ]);
in
{
  assertions = [
    {
      assertion = unpinned == [ ];
      message = "modules/core/ssh-known-hosts.nix: no host key pinned at ${
        lib.concatMapStringsSep ", " (d: "hosts/${d}/ssh_known_hosts") unpinned
      }: each must exist and hold one `<names> ssh-ed25519 <key>` line (docs/ssh-host-keys.md).";
    }
    {
      assertion = unpinned != [ ] || pinned == lib.sort lib.lessThan nodes;
      message = "modules/core/ssh-known-hosts.nix pins ${toString pinned}, not the deploy nodes of flake-modules/hosts.nix (${toString nodes}): another module replaced programs.ssh.knownHosts.";
    }
  ];
  programs.ssh.knownHosts = hosts;
  programs.ssh.extraConfig = lib.mkMerge [
    # a pre-push gate runs for minutes with the push connection idle, and GitHub closes it ("closed by remote host").
    # mkOrder 1400: after other modules' plain lines, which a Host line here would otherwise scope to github.com (a
    # guest's global ServerAliveInterval, workers/default.nix), and before the catch-all
    (lib.mkOrder 1400 ''
      Host github.com
        ServerAliveInterval 20
        ServerAliveCountMax 60
    '')
    # mkAfter: a per-host exception another module adds to extraConfig stays ahead of this catch-all (ssh keeps the
    # first value); the whole of extraConfig precedes nixpkgs' generated "Host *", and a user's own config precedes both
    (lib.mkAfter ''
      Host *
        StrictHostKeyChecking yes
        UpdateHostKeys no
    '')
  ];
}
