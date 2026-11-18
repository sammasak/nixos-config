# scripts/platform-record.sh as one package for the coordinator's timers and the root units alike, so each host
# carries the same store path.
{
  writeShellApplication,
  curl,
  jq,
  coreutils,
  findutils,
}:
writeShellApplication {
  name = "platform-record";
  runtimeInputs = [
    curl
    jq
    coreutils
    findutils
  ];
  text = builtins.readFile ../../scripts/platform-record.sh;
}
