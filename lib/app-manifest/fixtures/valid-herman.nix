{
  grants.herman = {
    owner = "sammasak";
    repo = "sammasak/herman";
    host = "acer-swift";
    hostnames = [ "herman-next" ];
    public = true;
  };
  apps.herman = import ../example/herman.nix;
}
