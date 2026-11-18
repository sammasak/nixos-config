# A service app with ingress behind Authentik, metrics and a backed-up volume, the shape the invalid fixtures bend.
{
  apiVersion = "v1alpha1";
  owner = "sammasak";
  environment = "staging";
  source = {
    repo = "sammasak/notes";
    rev = "0123456789abcdef0123456789abcdef01234567";
    package = "server";
  };
  health.path = "/healthz";
  ingress.notes.auth = "authentik";
  runtime.service = {
    program = "notes-server";
    metricsPath = "/metrics";
    resources = {
      memoryMiB = 128;
      cpuPercent = 50;
    };
    state.data.backup = "daily";
  };
}
