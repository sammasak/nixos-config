# Trial for retiring alert-bridge: black-pi's Alertmanager configuration with its bridge receiver swapped for a
# webhook whose `payload` renders ntfy's JSON publish format, posting to a loopback stub of ntfy's root URL.
# Alertmanager 0.33 reparses every rendered string as YAML and keeps it only when that yields a string: `[a, b]`
# becomes tags' list and `3` priority's int, but a body such as "Disk full:\nQuery: q" becomes an object. A leading
# tab makes that parse fail, so the body stays text; `ntfy-raw` sends the same body without it, to record the bug.
{ config, lib, ... }:
let
  blackPi = config.flake.nixosConfigurations.black-pi.config;
  lenovo = config.flake.nixosConfigurations.lenovo.config;
  am = blackPi.services.prometheus.alertmanager;
  prod = builtins.fromJSON (
    builtins.unsafeDiscardStringContext blackPi.services.prometheus.configText
  );
  ntfyPort = lenovo.homelab.ntfy.port;
  topic = lib.last (lib.splitString "/" lenovo.homelab.alertBridge.ntfyUrl);

  bySeverity =
    resolved: critical: warning: info: other:
    lib.concatStrings [
      ''{{ if eq .Status "resolved" }}${resolved}''
      ''{{ else if eq .CommonLabels.severity "critical" }}${critical}''
      ''{{ else if eq (or .CommonLabels.severity "warning") "warning" }}${warning}''
      ''{{ else if eq .CommonLabels.severity "info" }}${info}''
      "{{ else }}${other}{{ end }}"
    ];
  # alert-bridge's body: summary, description, a bullet for each of the first four alerts, the query last. No
  # template function subtracts, so the overflow line counts all alerts, not the ones left out. printf cuts runes,
  # not bytes: ntfy's 4096-byte message limit is only kept for mostly ASCII text. `$$` is envsubst's `$`.
  body = lib.concatStrings [
    ''{{ printf "%.1000s" .CommonAnnotations.summary }}''
    "{{ with .CommonAnnotations.description }}{{ if ne . $$.CommonAnnotations.summary }}"
    "\n"
    ''{{ printf "%.400s" . }}{{ end }}{{ end }}''
    "{{ range $$i, $$a := .Alerts }}{{ if lt $$i 4 }}"
    "{{ with or $$a.Labels.pod $$a.Labels.instance $$a.Labels.job $$a.Labels.namespace }}"
    "\n  • {{ . }}{{ end }}{{ end }}{{ end }}"
    "{{ if gt (len .Alerts) 4 }}\n  … {{ len .Alerts }} in all{{ end }}"
    "{{ with .CommonAnnotations.query }}\nQuery: "
    ''{{ printf "%.600s" . }}{{ end }}''
  ];
  receiver = name: guard: {
    inherit name;
    webhook_configs = [
      {
        url = "http://127.0.0.1:${toString ntfyPort}/";
        send_resolved = true;
        payload = {
          topic = if guard == "" then "${topic}-raw" else topic;
          title = lib.concatStrings [
            ''{{ if eq .Status "resolved" }}[RESOLVED]''
            ''{{ else }}[{{ or .CommonLabels.severity "warning" | toUpper }}]{{ end }}''
            " {{ .CommonLabels.alertname }}"
            ''{{ if and (ne .Status "resolved") (gt (len .Alerts) 1) }} ×{{ len .Alerts }}{{ end }}''
          ];
          tags =
            bySeverity "[white_check_mark, green_circle]" "[rotating_light, red_circle]"
              "[warning, orange_circle]"
              "[information_source]"
              "[warning]";
          priority = bySeverity "1" "4" "3" "1" "3";
          # an empty render goes out as null; the bridge also drops a link that is not plain http(s)
          click = ''{{ if match "^https?://[[:graph:]]+$" .CommonAnnotations.runbook_url }}{{ .CommonAnnotations.runbook_url }}{{ end }}'';
          message = guard + body;
        };
      }
    ];
  };
  colon = ''alertname = "SyntheticColon"'';
  amConfig = am.configuration // {
    route = am.configuration.route // {
      receiver = "ntfy";
      routes = [
        {
          receiver = "ntfy-raw";
          matchers = [ colon ];
          continue = true;
        }
        {
          receiver = "ntfy";
          matchers = [ colon ];
        }
      ]
      ++ map (
        r: r // lib.optionalAttrs (r.receiver == "alert-bridge") { receiver = "ntfy"; }
      ) am.configuration.route.routes;
    };
    receivers = [
      { name = "null"; }
      (receiver "ntfy" "\t")
      (receiver "ntfy-raw" "")
    ];
  };

  full = {
    summary = "Synthetic alert fired";
    description = "The payload test's textfile series is 1.";
    query = "homelab_synthetic_fire == 1";
    runbook_url = "https://github.com/sammasak/nixos-config/blob/main/docs/alert-runbooks.md#synthetic";
  };
  long = lib.concatStrings (lib.replicate 5000 "x");
  rule = alert: severity: annotations: {
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
            (rule "SyntheticPayload" "warning" full)
            (rule "SyntheticNoLinks" "critical" { summary = "No runbook, no query"; })
            (rule "SyntheticLong" "warning" { summary = long; })
            (rule "SyntheticColon" "warning" {
              summary = "Disk check failed:";
              inherit (full) query;
            })
          ];
        }
      ];
    }
  );
  bullet = "\n  • 127.0.0.1:9100";
  py = v: builtins.toJSON v;
in
{
  perSystem =
    { system, pkgs, ... }:
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.alert-payload-template = pkgs.testers.runNixOSTest {
        name = "alert-payload-template";
        nodes.machine = {
          services.prometheus = {
            enable = true;
            configText = builtins.toJSON {
              global = prod.global // {
                scrape_interval = "5s";
                evaluation_interval = "5s";
              };
              alerting.alertmanagers = [
                { static_configs = [ { targets = [ "127.0.0.1:${toString am.port}" ]; } ]; }
              ];
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
              listenAddress = "127.0.0.1";
              inherit (am) port extraFlags;
              configuration = amConfig;
            };
          };
          systemd.tmpfiles.rules = [ "d /run/textfile 0755 root root -" ];
          # ntfy's root URL, which takes a publish as a JSON object; one line per publish
          systemd.services.ntfy-stub = {
            wantedBy = [ "multi-user.target" ];
            serviceConfig.StateDirectory = "ntfy-stub";
            serviceConfig.ExecStart = pkgs.writers.writePython3 "ntfy-stub" { doCheck = false; } ''
              import json
              from http.server import BaseHTTPRequestHandler, HTTPServer


              class Root(BaseHTTPRequestHandler):
                  def do_POST(self):
                      body = self.rfile.read(int(self.headers["Content-Length"]))
                      line = {"path": self.path, "type": self.headers["Content-Type"]}
                      line |= json.loads(body)
                      with open("/var/lib/ntfy-stub/messages.jsonl", "a") as f:
                          f.write(json.dumps(line) + "\n")
                      self.send_response(200)
                      self.end_headers()


              HTTPServer(("127.0.0.1", ${toString ntfyPort}), Root).serve_forever()
            '';
          };
        };
        testScript = ''
          import json

          def published(topic):
              out = machine.succeed("cat /var/lib/ntfy-stub/messages.jsonl 2>/dev/null || true")
              return [m for m in map(json.loads, out.splitlines()) if m["topic"] == topic]

          def only(title, topic=${py topic}):
              found = [m for m in published(topic) if m["title"] == title]
              assert len(found) == 1, (title, published(topic))
              return found[0]

          def wait_for(n):
              machine.wait_until_succeeds(f"test $(wc -l < /var/lib/ntfy-stub/messages.jsonl) -ge {n}", timeout=420)

          start_all()
          machine.wait_for_unit("alertmanager.service")
          machine.wait_for_unit("prometheus.service")
          machine.wait_for_unit("ntfy-stub.service")

          sent = {"path": "/", "type": "application/json", "topic": ${py topic}}
          body = ${py "\t${full.summary}\n${full.description}${bullet}\nQuery: ${full.query}"}
          page = sent | {"message": body, "click": ${py full.runbook_url}}

          machine.succeed("echo 'homelab_synthetic_fire 1' > /run/textfile/synthetic.prom")
          # four groups on the main topic and the colon one again on the raw topic
          wait_for(5)
          machine.sleep(10)
          assert len(published(${py topic})) == 4, published(${py topic})

          with subtest("firing: title, tags and priority by severity, runbook as click, summary and query"):
              got = only("[WARNING] SyntheticPayload")
              assert got == page | {"title": "[WARNING] SyntheticPayload", "tags": ["warning", "orange_circle"], "priority": 3}, got

          with subtest("no runbook and no query still delivers"):
              got = only("[CRITICAL] SyntheticNoLinks")
              want = sent | {"title": "[CRITICAL] SyntheticNoLinks", "tags": ["rotating_light", "red_circle"], "priority": 4, "click": None, "message": ${py "\tNo runbook, no query${bullet}"}}
              assert got == want, got

          with subtest("an oversized summary is cut to 1000 characters"):
              got = only("[WARNING] SyntheticLong")
              assert got["message"] == "\t" + "x" * 1000 + ${py bullet}, len(got["message"])

          with subtest("a summary ending in a colon stays text behind the guard"):
              got = only("[WARNING] SyntheticColon")
              assert got["message"] == ${py "\tDisk check failed:${bullet}\nQuery: ${full.query}"}, got

          with subtest("without the guard the same body goes out as an object"):
              got = only("[WARNING] SyntheticColon", ${py "${topic}-raw"})
              print("raw colon page:", json.dumps(got))
              assert got["message"] == {"Disk check failed": "• 127.0.0.1:9100", "Query": ${py full.query}}, got

          machine.succeed("echo 'homelab_synthetic_fire 0' > /run/textfile/synthetic.prom")
          # resolved goes out at each group's next flush, group_interval (5m) after the firing one
          wait_for(10)

          with subtest("resolved: its own title, tags and priority, the same body and click"):
              got = only("[RESOLVED] SyntheticPayload")
              assert got == page | {"title": "[RESOLVED] SyntheticPayload", "tags": ["white_check_mark", "green_circle"], "priority": 1}, got
        '';
      };
    };
}
