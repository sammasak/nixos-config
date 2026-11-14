# Experiment 3 of #358, a scratch test: nix-build experiments/scale-to-zero-test.nix
{
  pkgs ? import (builtins.getFlake (toString ../.)).inputs.nixpkgs { },
}:
pkgs.testers.runNixOSTest {
  name = "scale-to-zero";
  nodes.host =
    { config, lib, pkgs, ... }:
    {
      virtualisation.memorySize = 1536;
      # qdrant 1.18.2 of the locked nixpkgs is not on cache.nixos.org; grafana is, and also lacks socket activation.
      services.grafana = {
        enable = true;
        settings.security.secret_key = "scratch-vm-only";
      };
      systemd.services.grafana = {
        wantedBy = lib.mkForce [ ];
        unitConfig.StopWhenUnneeded = true;
        serviceConfig = {
          ExecStartPost = "${pkgs.curl}/bin/curl -fsS -o /dev/null --retry 60 --retry-delay 1 --retry-connrefused http://127.0.0.1:3000/api/health";
          IPAddressDeny = "any";
          IPAddressAllow = "localhost";
        };
      };
      # The sketch's 6334 is qdrant's own gRPC port; the socket would have taken it first.
      systemd.sockets.grafana-proxy = {
        wantedBy = [ "sockets.target" ];
        listenStreams = [ "3001" ];
      };
      systemd.services.grafana-proxy = {
        requires = [ "grafana.service" "grafana-proxy.socket" ];
        after = [ "grafana.service" "grafana-proxy.socket" ];
        serviceConfig = {
          ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd --exit-idle-time=20s 127.0.0.1:3000";
          DynamicUser = true;
        };
      };
      environment.systemPackages = [ pkgs.curl ];

      specialisation.noready.configuration.systemd.services.grafana.serviceConfig.ExecStartPost = lib.mkForce [ ];
      # A documentation-range address no interface holds: bind fails at startup, eval passes.
      specialisation.broken.configuration.services.grafana.settings.server.http_addr = lib.mkForce "203.0.113.1";
    };
  nodes.outside =
    { pkgs, ... }:
    {
      systemd.services.plain-http = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8000 --directory /etc";
      };
      networking.firewall.allowedTCPPorts = [ 8000 ];
    };
  testScript = ''
    import time

    def show(unit, props="MemoryCurrent,MemoryPeak,ActiveState,SubState,NRestarts"):
        return host.succeed(f"systemctl show {unit} -p {props}").strip().replace("\n", " ")

    def cold_curl():
        return float(host.succeed("curl -fsS -o /dev/null -w '%{time_total}' http://127.0.0.1:3001/api/health"))

    def to_zero():
        host.succeed("systemctl stop grafana-proxy.service grafana.service")
        host.fail("systemctl is-active grafana.service")

    start_all()
    host.wait_for_unit("sockets.target")
    outside.wait_for_open_port(8000)
    host.fail("systemctl is-active grafana.service")
    print("IDLE grafana:", show("grafana.service"))
    print("IDLE proxy:", show("grafana-proxy.service"))

    first = cold_curl()
    host.succeed("systemctl is-active grafana.service")
    print("FIRST-COLD-S:", first)
    print("AFTER-FIRST grafana:", show("grafana.service"))
    print("AFTER-FIRST proxy:", show("grafana-proxy.service"))
    print("SECURITY grafana:", host.succeed("systemd-analyze security grafana.service | tail -1"))
    print("SECURITY proxy:", host.succeed("systemd-analyze security grafana-proxy.service | tail -1"))

    cg = "/sys/fs/cgroup/system.slice/grafana.service/cgroup.procs"
    host.succeed("curl -fsS --max-time 5 -o /dev/null http://outside:8000/")
    host.succeed(f"sh -c 'echo $$ > {cg} && exec curl -fsS --max-time 5 -o /dev/null http://127.0.0.1:3000/api/health'")
    host.fail(f"sh -c 'echo $$ > {cg} && exec curl -fsS --max-time 5 -o /dev/null http://outside:8000/'")
    print("FILTER: grafana cgroup reaches localhost, not the other node")

    t0 = time.monotonic()
    host.wait_until_fails("systemctl is-active grafana.service", timeout=90)
    print("IDLE-STOP after", round(time.monotonic() - t0, 1), "s;", show("grafana-proxy.service", "ActiveState"))
    host.succeed("curl -fsS http://127.0.0.1:3001/api/health")

    cold = []
    for _ in range(5):
        to_zero()
        cold.append(cold_curl())
    warm = [cold_curl() for _ in range(5)]
    print("COLD-S:", cold, "median", sorted(cold)[2])
    print("WARM-S:", warm, "median", sorted(warm)[2])

    # Six starts inside 10 s trip the default start limit and the socket stops listening.
    time.sleep(11)
    before = int(host.succeed("systemctl show grafana -p MainPID --value"))
    host.succeed("systemctl kill -s KILL grafana.service")
    time.sleep(1)
    print("KILL9 right after:", show("grafana.service"), "| proxy", show("grafana-proxy.service", "ActiveState,SubState"))
    t0 = time.monotonic()
    host.succeed("curl -fsS --retry 30 --retry-delay 1 --retry-all-errors -o /dev/null http://127.0.0.1:3001/api/health")
    print("KILL9: served again after", round(time.monotonic() - t0, 2), "s;", show("grafana.service"))
    assert int(host.succeed("systemctl show grafana -p MainPID --value")) != before

    time.sleep(11)
    host.succeed("/run/current-system/specialisation/noready/bin/switch-to-configuration test")
    trap = []
    for _ in range(5):
        to_zero()
        rc, out = host.execute("curl -sS -o /dev/null -w '%{http_code} %{time_total}' http://127.0.0.1:3001/api/health 2>&1")
        trap.append((rc, out.strip()))
        time.sleep(3)
    print("NO-READINESS-GATE first requests:", trap)
    host.succeed("/run/booted-system/bin/switch-to-configuration test")

    time.sleep(11)
    to_zero()
    host.succeed("/run/current-system/specialisation/broken/bin/switch-to-configuration test")
    t0 = time.monotonic()
    rc, out = host.execute("curl -sS --max-time 120 -o /dev/null -w '%{http_code}' http://127.0.0.1:3001/api/health 2>&1")
    print("BROKEN: curl rc", rc, out.strip(), "after", round(time.monotonic() - t0, 1), "s")
    print("BROKEN grafana:", show("grafana.service", "ActiveState,SubState,Result,NRestarts"))
    print("BROKEN proxy:", show("grafana-proxy.service", "ActiveState,SubState,Result"))
    print("BROKEN socket:", show("grafana-proxy.socket", "ActiveState,SubState,Result"))
    print(host.execute("journalctl -u grafana.service -u grafana-proxy.service -u grafana-proxy.socket --no-pager | tail -10")[1])

    host.succeed("/run/booted-system/bin/switch-to-configuration test")
    host.execute("systemctl reset-failed grafana.service grafana-proxy.service grafana-proxy.socket")
    host.succeed("systemctl start grafana-proxy.socket")
    host.succeed("curl -fsS --retry 10 --retry-delay 1 --retry-all-errors -o /dev/null http://127.0.0.1:3001/api/health")
    print("RECOVERED:", show("grafana-proxy.socket", "ActiveState,SubState"))
  '';
}
