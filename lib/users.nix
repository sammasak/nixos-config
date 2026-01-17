# User identity configuration
# Define user-specific data here (git credentials, SSH keys, etc.)
# Referenced by flake.nix when defining hosts

{
  lukas = {
    git = {
      userName = "sammasak";
      email = "23168291+sammasak@users.noreply.github.com";
    };
    sshKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDij+mo4z7FsJdwY1GKqrXGqSLIJoq/lNlhW+V1eKMDH lukas@lenovo-21CB001PMX"
    ];
  };
}
