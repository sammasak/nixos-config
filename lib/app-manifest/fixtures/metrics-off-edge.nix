{
  grants.notes = {
    owner = "sammasak";
    repo = "sammasak/notes";
    host = "msi-ms7758";
  };
  apps.notes = import ./notes.nix // {
    ingress = { };
  };
}
