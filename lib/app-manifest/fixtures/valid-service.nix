{
  imports = [ ./valid-herman.nix ];
  grants.notes = {
    owner = "sammasak";
    repo = "sammasak/notes";
    host = "acer-swift";
    hostnames = [ "notes" ];
  };
  apps.notes = import ./notes.nix;
}
