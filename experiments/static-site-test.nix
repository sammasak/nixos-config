# Experiment 2 of #358, a scratch test: nix-build experiments/static-site-test.nix
{
  pkgs ? import (builtins.getFlake (toString ../.)).inputs.nixpkgs { },
}:
pkgs.testers.runNixOSTest {
  name = "static-site";
  nodes.web =
    { lib, pkgs, ... }:
    {
      services.static-web-server = {
        enable = true;
        listen = "[::]:8080";
        root = pkgs.writeTextDir "index.html" "hello";
      };
      systemd.services.static-web-server.wantedBy = lib.mkForce [ ];
      networking.firewall.allowedTCPPorts = [ 8080 ];

      # root must exist: BindReadOnlyPaths fails the unit before the binary runs.
      specialisation.broken.configuration.services.static-web-server.root = lib.mkForce "/srv/missing";
    };
  nodes.client = { pkgs, ... }: { environment.systemPackages = [ pkgs.curl ]; };
  testScript = ''
    import time

    def show(unit, props="MemoryCurrent,MemoryPeak,ActiveState,SubState,NRestarts"):
        return web.succeed(f"systemctl show {unit} -p {props}").strip().replace("\n", " ")

    def cold_curl():
        return float(client.succeed("curl -fsS -o /dev/null -w '%{time_total}' http://web:8080/"))

    start_all()
    web.wait_for_unit("sockets.target")
    client.wait_for_unit("multi-user.target")
    web.fail("systemctl is-active static-web-server.service")
    print("IDLE service:", show("static-web-server.service"))
    print("IDLE socket:", show("static-web-server.socket", "MemoryCurrent,ActiveState"))

    client.succeed("curl -fsS http://web:8080/ | grep hello")
    web.succeed("systemctl is-active static-web-server.service")
    print("AFTER-FIRST:", show("static-web-server.service"))
    print("SECURITY:", web.succeed("systemd-analyze security static-web-server.service | tail -1"))

    time.sleep(60)
    web.succeed("systemctl is-active static-web-server.service")
    print("AFTER-60S-IDLE:", show("static-web-server.service"))

    cold = []
    for _ in range(5):
        web.succeed("systemctl stop static-web-server.service")
        web.fail("systemctl is-active static-web-server.service")
        cold.append(cold_curl())
    warm = [cold_curl() for _ in range(5)]
    print("COLD-S:", cold, "median", sorted(cold)[2])
    print("WARM-S:", warm, "median", sorted(warm)[2])

    # Six starts inside 10 s trip the default start limit and the socket stops listening.
    time.sleep(11)
    before = int(web.succeed("systemctl show static-web-server -p MainPID --value"))
    web.succeed("systemctl kill -s KILL static-web-server.service")
    t0 = time.monotonic()
    client.succeed("curl -fsS --retry 20 --retry-delay 1 --retry-all-errors http://web:8080/ | grep hello")
    print("KILL9: served again after", round(time.monotonic() - t0, 2), "s;", show("static-web-server.service"))
    after = int(web.succeed("systemctl show static-web-server -p MainPID --value"))
    assert after != before, "expected a new process after kill -9"

    time.sleep(11)
    web.succeed("/run/current-system/specialisation/broken/bin/switch-to-configuration test")
    rc, out = client.execute("curl -sS --max-time 10 -o /dev/null -w '%{http_code}' http://web:8080/ 2>&1")
    print("BROKEN: curl rc", rc, out)
    print("BROKEN service:", show("static-web-server.service", "ActiveState,SubState,Result,NRestarts"))
    print("BROKEN socket:", show("static-web-server.socket", "ActiveState,SubState,Result"))
    print(web.execute("journalctl -u static-web-server.service -u static-web-server.socket --no-pager | tail -8")[1])

    rc, _ = web.execute("/run/booted-system/bin/switch-to-configuration test")
    print("ROLLBACK: switch-to-configuration rc", rc, show("static-web-server.socket", "ActiveState,SubState"))
    rc, out = client.execute("curl -sS --max-time 10 http://web:8080/ 2>&1")
    print("ROLLBACK before reset-failed: curl rc", rc, out.strip())
    web.execute("systemctl reset-failed static-web-server.service static-web-server.socket")
    client.succeed("curl -fsS --retry 10 --retry-delay 1 --retry-all-errors http://web:8080/ | grep hello")
    print("RECOVERED:", show("static-web-server.socket", "ActiveState,SubState"))
  '';
}
