# open-webui-proxy-rebind's premise in QEMU (open-webui.nix): a switch that adds a ListenStream binds it only through a
# oneshot keyed on the socket's unit, and a plain socket keeps its old listeners. If the plain one ever binds too,
# switch-to-configuration handles sockets (nixpkgs#74899) and the rebind unit can go. `nix build .#socket-rebind-vm`.
{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "socket-rebind";

  nodes.machine =
    { config, lib, ... }:
    let
      socket = name: {
        systemd.sockets.${name} = {
          wantedBy = [ "sockets.target" ];
          listenStreams = [ "/run/${name}-a.sock" ];
        };
        # still running at the switch, as the proxy is for 5 min after a request
        systemd.services.${name}.serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
      };
    in
    lib.mkMerge [
      (socket "plain")
      (socket "rebound")
      {
        # the same shape as open-webui-proxy-rebind
        systemd.services.rebound-rebind = {
          wantedBy = [ "multi-user.target" ];
          after = [ "rebound.socket" ];
          restartTriggers = [ config.systemd.units."rebound.socket".unit ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = [
              "${config.systemd.package}/bin/systemctl stop rebound.service"
              "${config.systemd.package}/bin/systemctl restart rebound.socket"
            ];
          };
        };
        specialisation.moved.configuration = {
          systemd.sockets.plain.listenStreams = [ "/run/plain-b.sock" ];
          systemd.sockets.rebound.listenStreams = [ "/run/rebound-b.sock" ];
        };
      }
    ];

  testScript = ''
    machine.wait_for_unit("rebound-rebind.service")
    machine.succeed("test -S /run/plain-a.sock -a -S /run/rebound-a.sock")
    machine.succeed("systemctl start plain.service rebound.service")

    machine.succeed("/run/booted-system/specialisation/moved/bin/switch-to-configuration test >&2")

    with subtest("the rebind unit binds the new ListenStream at the switch"):
        machine.succeed("test -S /run/rebound-b.sock")
        machine.succeed("systemctl is-active rebound.socket")
    with subtest("a plain socket does not: the gap the rebind unit covers"):
        machine.fail("test -S /run/plain-b.sock")
  '';
}
