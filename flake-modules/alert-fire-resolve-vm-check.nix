# Prometheus rule to Alertmanager to ntfy, firing and then resolved. Two VMs on the production addresses: black-pi's
# Alertmanager configuration and alerting block verbatim, and ntfy with lenovo's settings, read back through its poll
# API. The synthetic rules cover a full page, one with no runbook or query, an oversized summary, a summary ending in
# a colon (also sent once more without the payload's YAML guard, which ntfy must refuse) and an info twin that must
# reach Alertmanager and no one else. Nothing leaves the VMs.
{ config, lib, ... }:
let
  blackPi = config.flake.nixosConfigurations.black-pi.config;
  lenovo = config.flake.nixosConfigurations.lenovo.config;
  inherit (blackPi.sam.fleet) hosts ntfy;
  am = blackPi.services.prometheus.alertmanager;
  prod = builtins.fromJSON (
    builtins.unsafeDiscardStringContext blackPi.services.prometheus.configText
  );
  hook =
    lib.head
      (lib.findFirst (r: r.name == "ntfy") null am.configuration.receivers).webhook_configs;
  inherit (hook.payload) topic;
  raw = {
    name = "ntfy-raw";
    webhook_configs = [
      (
        hook
        // {
          payload = hook.payload // {
            topic = "${topic}-raw";
            message = lib.removePrefix "\t" hook.payload.message;
          };
        }
      )
    ];
  };
  colon = ''alertname = "SyntheticColon"'';
  amConfig = am.configuration // {
    route = am.configuration.route // {
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
      ++ am.configuration.route.routes;
    };
    receivers = am.configuration.receivers ++ [ raw ];
  };
  on = host: {
    networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
      {
        address = hosts.${host}.address;
        prefixLength = 24;
      }
    ];
  };
  full = {
    summary = "Synthetic alert fired";
    description = "The fire and resolve test's textfile series is 1.";
    query = "homelab_synthetic_fire == 1";
    runbook_url = "https://github.com/sammasak/nixos-config/blob/main/docs/alert-runbooks.md#synthetic";
  };
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
            (rule "SyntheticFireResolve" "warning" full)
            (rule "SyntheticInfo" "info" full)
            (rule "SyntheticNoLinks" "critical" { summary = "No runbook, no query"; })
            (rule "SyntheticLong" "warning" { summary = lib.concatStrings (lib.replicate 5000 "x"); })
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
  py = builtins.toJSON;
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
              inherit (am) listenAddress port extraFlags;
              configuration = amConfig;
            };
          };
          systemd.tmpfiles.rules = [ "d /run/textfile 0755 root root -" ];
          environment.systemPackages = [ pkgs.curl ];
        };
        nodes.ntfy = {
          imports = [ (on ntfy.host) ];
          services.ntfy-sh = {
            enable = true;
            inherit (lenovo.services.ntfy-sh) settings;
          };
          networking.firewall.allowedTCPPorts = [ ntfy.port ];
          environment.systemPackages = [ pkgs.curl ];
        };
        testScript = ''
          import json

          def pages(topic=${py topic}):
              *lines, status = ntfy.succeed(f"curl -s -w '\\n%{{http_code}}' 'http://127.0.0.1:${toString ntfy.port}/{topic}/json?poll=1'").splitlines()
              assert status == "200", (topic, status, lines)
              return [json.loads(line) for line in lines if line]

          def only(title):
              found = [m for m in pages() if m.get("title") == title]
              assert len(found) == 1, (title, pages())
              m = found[0]
              return {"message": m["message"], "tags": m.get("tags"), "priority": m.get("priority", 3), "click": m.get("click")}

          # every 15 s: a poll each second for 5 minutes can run into ntfy's per-visitor request limit
          def wait_for(n):
              ntfy.succeed(f"timeout 420 sh -c 'until [ $(curl -sf http://127.0.0.1:${toString ntfy.port}/${topic}/json?poll=1 | wc -l) -ge {n} ]; do sleep 15; done'")

          start_all()
          alerting.wait_for_unit("alertmanager.service")
          alerting.wait_for_unit("prometheus.service")
          ntfy.wait_for_unit("ntfy-sh.service")
          ntfy.wait_for_open_port(${toString ntfy.port})

          page = {"message": ${py "${full.summary}\n${full.description}${bullet}\nQuery: ${full.query}"}, "click": ${py full.runbook_url}}

          alerting.succeed("echo 'homelab_synthetic_fire 1' > /run/textfile/synthetic.prom")
          # the info twin is in Alertmanager, so its absence at ntfy is the route, not a rule that never fired
          alerting.wait_until_succeeds(
              "curl -sf 'http://${am.listenAddress}:${toString am.port}/api/v2/alerts?filter=alertname=\"SyntheticInfo\"' | grep -q SyntheticInfo",
              timeout=120,
          )
          wait_for(4)
          alerting.sleep(15)

          with subtest("one page per group, none for info"):
              assert sorted(m["title"] for m in pages()) == ["[CRITICAL] SyntheticNoLinks", "[WARNING] SyntheticColon", "[WARNING] SyntheticFireResolve", "[WARNING] SyntheticLong"], pages()

          with subtest("firing: severity's title, tags and priority, the runbook as click, summary and query"):
              got = only("[WARNING] SyntheticFireResolve")
              assert got == page | {"tags": ["warning", "orange_circle"], "priority": 3}, got

          with subtest("no runbook and no query still pages"):
              got = only("[CRITICAL] SyntheticNoLinks")
              assert got == {"message": ${py "No runbook, no query${bullet}"}, "tags": ["rotating_light", "red_circle"], "priority": 4, "click": None}, got

          with subtest("an oversized summary is cut to 1000 characters"):
              got = only("[WARNING] SyntheticLong")
              assert got["message"] == "x" * 1000 + ${py bullet}, len(got["message"])

          with subtest("a summary ending in a colon stays text"):
              got = only("[WARNING] SyntheticColon")
              assert got["message"] == ${py "Disk check failed:${bullet}\nQuery: ${full.query}"}, got

          with subtest("without the guard Alertmanager sends that body as an object and ntfy refuses it"):
              assert pages(${py "${topic}-raw"}) == [], pages(${py "${topic}-raw"})
              refused = alerting.succeed("journalctl -u alertmanager --no-pager | grep 'ntfy-raw' | grep -m1 '400'")
              print("raw colon page:", refused)

          alerting.succeed("echo 'homelab_synthetic_fire 0' > /run/textfile/synthetic.prom")
          # resolved goes out at each group's next flush, group_interval (5m) after the firing one
          wait_for(8)

          with subtest("resolved: its own title, tags and priority, the same body and click"):
              got = only("[RESOLVED] SyntheticFireResolve")
              assert got == page | {"tags": ["white_check_mark", "green_circle"], "priority": 1}, got
        '';
      };
    };
}
