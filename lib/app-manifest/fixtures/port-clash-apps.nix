{
  imports = [ ./valid-service.nix ];
  grants.wiki = {
    owner = "sammasak";
    repo = "sammasak/wiki";
    host = "acer-swift";
    hostnames = [ "wiki" ];
  };
  apps.wiki = import ./notes.nix // {
    source = {
      repo = "sammasak/wiki";
      rev = "89abcdef0123456789abcdef0123456789abcdef";
    };
    ingress.wiki.auth = "authentik";
  };
}
