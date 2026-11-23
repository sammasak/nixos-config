# One alert, Prometheus rule to Alertmanager to alert-bridge to ntfy, firing and then resolved (#624). Two VMs on the
# production addresses: black-pi's Alertmanager configuration and alerting block verbatim, lenovo's alert-bridge unit
# verbatim (its IP filter included), and a loopback stub on ntfy's port in place of ntfy. A synthetic rule on a
# textfile series fires and resolves; an info twin must reach Alertmanager and no one else. Nothing leaves the VMs.
{ config, lib, ... }:
let
  blackPi = config.flake.nixosConfigurations.black-pi.config;
  lenovo = config.flake.nixosConfigurations.lenovo.config;
  inherit (blackPi.sam.fleet) hosts;
  am = blackPi.services.prometheus.alertmanager;
  bridge = lenovo.systemd.services.alert-bridge;
  # only global and alerting are kept: the rule files and scrapes are black-pi's, and aarch64
  prod = builtins.fromJSON (
    builtins.unsafeDiscardStringContext blackPi.services.prometheus.configText
  );
  on = host: {
    networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
      {
        address = hosts.${host}.address;
        prefixLength = 24;
      }
    ];
  };
  annotations = {
    summary = "Synthetic alert fired";
    description = "The fire and resolve test's textfile series is 1.";
    query = "homelab_synthetic_fire == 1";
    runbook_url = "https://github.com/sammasak/nixos-config/blob/main/docs/alert-runbooks.md#synthetic";
  };
  rule = alert: severity: {
    inherit alert annotations;
    expr = "homelab_synthetic_fire == 1";
    labels = { inherit severity; };
  };
  rules = builtins.toFile "synthetic.yaml" (
    builtins.toJSON {
      groups = [
        {
          name = "synthetic";
          rules = [
            (rule "SyntheticFireResolve" "warning")
            (rule "SyntheticInfo" "info")
          ];
        }
      ];
    }
  );
in
{
  perSystem =
    { system, pkgs, ... }:
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.alert-fire-resolve = pkgs.testers.runNixOSTest {
        name = "alert-fire-resolve";
        nodes.alerting = {
          imports = [ (on "black-pi") ];
          services.prometheus = {
            enable = true;
            configText = builtins.toJSON {
              global = prod.global // {
                scrape_interval = "5s";
                evaluation_interval = "5s";
              };
              inherit (prod) alerting;
              rule_files = [ rules ];
              scrape_configs = [
                {
                  job_name = "node-exporter";
                  static_configs = [ { targets = [ "127.0.0.1:9100" ]; } ];
                }
              ];
            };
            exporters.node = {
              enable = true;
              listenAddress = "127.0.0.1";
              enabledCollectors = [ "textfile" ];
              extraFlags = [ "--collector.textfile.directory=/run/textfile" ];
            };
            alertmanager = {
              enable = true;
              inherit (am)
                listenAddress
                port
                extraFlags
                configuration
                ;
            };
          };
          systemd.tmpfiles.rules = [ "d /run/textfile 0755 root root -" ];
          environment.systemPackages = [ pkgs.curl ];
        };
        nodes.bridge = {
          imports = [ (on "lenovo-21CB001PMX") ];
          virtualisation.memorySize = 512;
          networking.firewall.allowedTCPPorts = [ lenovo.homelab.alertBridge.port ];
          systemd.services.alert-bridge = {
            inherit (bridge) description serviceConfig;
            environment = removeAttrs bridge.environment [ "PATH" ];
            wantedBy = [ "multi-user.target" ];
          };
          # ntfy's address as the bridge has it, one JSON line per publish
          systemd.services.ntfy-stub = {
            wantedBy = [ "multi-user.target" ];
            serviceConfig.StateDirectory = "ntfy-stub";
            serviceConfig.ExecStart =
              let
                url = lib.splitString ":" (lib.removePrefix "http://" bridge.environment.ALERT_BRIDGE_NTFY_URL);
              in
              pkgs.writers.writePython3 "ntfy-stub" { flakeIgnore = [ "E501" ]; } ''
                import json
                from http.server import BaseHTTPRequestHandler, HTTPServer


                class Topic(BaseHTTPRequestHandler):
                    def do_POST(self):
                        n = int(self.headers["Content-Length"])
                        body = self.rfile.read(n).decode()
                        h = self.headers
                        line = {"path": self.path, "body": body}
                        for k in ("Title", "Tags", "Priority", "Click", "Content-Type"):
                            line[k] = h[k]
                        with open("/var/lib/ntfy-stub/messages.jsonl", "a") as f:
                            f.write(json.dumps(line) + "\n")
                        self.send_response(200)
                        self.end_headers()


                HTTPServer(("${lib.head url}", ${lib.head (lib.splitString "/" (lib.elemAt url 1))}), Topic).serve_forever()
              '';
          };
        };
        testScript = ''
          import json

          def messages():
              out = bridge.succeed("cat /var/lib/ntfy-stub/messages.jsonl 2>/dev/null || true")
              return [json.loads(line) for line in out.splitlines()]

          start_all()
          alerting.wait_for_unit("alertmanager.service")
          alerting.wait_for_unit("prometheus.service")
          bridge.wait_for_unit("alert-bridge.service")
          bridge.wait_for_unit("ntfy-stub.service")

          # the page carries the rule's query and, as the tap target, its runbook
          body = "${annotations.summary}\n${annotations.description}\n  • 127.0.0.1:9100\nQuery: ${annotations.query}"
          sent = {
              "path": "/homelab-alerts",
              "body": body,
              "Click": "${annotations.runbook_url}",
              "Content-Type": "text/plain; charset=utf-8",
          }

          alerting.succeed("echo 'homelab_synthetic_fire 1' > /run/textfile/synthetic.prom")
          # the info twin is in Alertmanager, so its absence at the stub is the route, not a rule that never fired
          alerting.wait_until_succeeds(
              "curl -sf 'http://${am.listenAddress}:${toString am.port}/api/v2/alerts?filter=alertname=\"SyntheticInfo\"' | grep -q SyntheticInfo",
              timeout=120,
          )
          bridge.wait_until_succeeds("test -s /var/lib/ntfy-stub/messages.jsonl", timeout=180)
          assert messages() == [sent | {"Title": "[WARNING] SyntheticFireResolve", "Tags": "warning,orange_circle", "Priority": "default"}], messages()

          alerting.succeed("echo 'homelab_synthetic_fire 0' > /run/textfile/synthetic.prom")
          # resolved goes out at the group's next flush, group_interval (5m) after the firing one
          bridge.wait_until_succeeds("test $(wc -l < /var/lib/ntfy-stub/messages.jsonl) -ge 2", timeout=420)
          assert messages()[1:] == [sent | {"Title": "[RESOLVED] SyntheticFireResolve", "Tags": "white_check_mark,green_circle", "Priority": "min"}], messages()
        '';
      };
    };
}
