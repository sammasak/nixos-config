# The #139 host adapter as a package. runtimeInputs pins the herdr CLI it speaks:
# a host whose server runs another herdr version answers through this client.
{ pkgs }:
pkgs.writeShellApplication {
  name = "agent-runtime-herdr";
  runtimeInputs = with pkgs; [ coreutils findutils jq util-linux systemd herdr inetutils ];
  # jq programs are single-quoted on purpose
  excludeShellChecks = [ "SC2016" ];
  text = builtins.readFile ./agent-runtime-herdr.sh;
}
