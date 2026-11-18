# herman's manifest as its own repository would carry it: the static web shell the edge serves from its herman site
# today, here under a second name, since admission refuses a name the edge already serves.
{
  apiVersion = "v1alpha1";
  owner = "sammasak";
  environment = "production";
  source = {
    repo = "sammasak/herman";
    rev = "7f41955749fc473d11173ffbc18e76973a7bb224";
    package = "web";
  };
  health.path = "/index.html";
  ingress.herman-next.auth = "public";
  runtime.static.spa = true;
}
