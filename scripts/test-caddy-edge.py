"""acer's Caddy edge (modules/homelab/edge.nix), as `caddy adapt` reads the deployed Caddyfile: the admin API is a
socket only caddy may write to, every name has its route and backend, chat and grafana pass forward auth before
their backend with the five X-Authentik-* fields copied, otlp admits the fleet alone, llm-gateway serves /v1 only,
open-webui listens on the edge socket alone, the apex and any other name under the wildcard are 404, herman is
its Nix build with the Cache-Control matrix and SPA fallback of its deploy/nginx.conf, and the metrics server is
plain HTTP on its own port, serving Caddy's /metrics and, at /authentik/server/metrics and /authentik/worker/metrics,
Authentik's loopback metrics listeners only, which black-pi scrapes at the fleet address."""
import json
import subprocess
import sys

import gate_probe

failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


P = gate_probe.section("caddy-edge")
fleet = P["fleet"]
config = json.loads(subprocess.run([P["caddy"], "adapt", "--config", P["configFile"], "--adapter", "caddyfile"],
                                   check=True, stdout=subprocess.PIPE, text=True).stdout)

authentik = "127.0.0.1:9000"
backends = {
    "auth": authentik,
    "chat": "unix//run/open-webui-edge.sock",
    "grafana": f"{fleet['black-pi']}:3000",
    "llm-gateway": "127.0.0.1:8081",
    "otlp": "127.0.0.1:4318",
    "ntfy": f"{fleet['lenovo-21CB001PMX']}:{P['ntfyPort']}",
}
headers = {"X-Authentik-Username", "X-Authentik-Groups", "X-Authentik-Email", "X-Authentik-Name", "X-Authentik-Uid"}


def flatten(handlers, matchers=()):
    """Each handler in the order Caddy runs it, with the matchers on the way to it."""
    for h in handlers:
        yield h, matchers
        if h.get("handler") == "subroute":
            for r in h["routes"]:
                yield from flatten(r["handle"], matchers + tuple(r.get("match", [])))


def dials(h):
    return [u["dial"] for u in h.get("upstreams", [])] if h.get("handler") == "reverse_proxy" else []


def is_forward_auth(h):
    return h.get("handler") == "reverse_proxy" and h.get("rewrite", {}).get("uri") == "/outpost.goauthentik.io/auth/caddy"


check(config.get("admin") == {"listen": "unix//run/caddy/admin.sock|0200"},
      f"the admin API listens on caddy's own socket, not TCP {config.get('admin')}")
check(P["enableReload"] is True, "a Caddyfile change reloads Caddy instead of restarting it (every site drops)")
check(P["failing"]["acer"] == [], f"acer fails no assertion {P['failing']['acer']}")
check(any("services.caddy" in m and "open-webui" in m for m in P["failing"]["noCaddy"]),
      f"the open-webui edge socket without Caddy is rejected {P['failing']['noCaddy']}")

servers = config["apps"]["http"]["servers"]
metrics_listen = f":{P['edgeMetrics']['port']}"
metrics_target = f"{P['edgeMetrics']['address']}:{P['edgeMetrics']['port']}"
metrics = {k: v for k, v in servers.items() if metrics_listen in v.get("listen", [])}
servers = {k: v for k, v in servers.items() if k not in metrics}
check(len(metrics) == 1 and all(v["listen"] == [metrics_listen] for v in metrics.values()),
      f"one server listens for metrics, on {metrics_listen} alone {[v.get('listen') for v in metrics.values()]}")
served = [(h.get("handler"), m) for v in metrics.values() for r in v.get("routes", [])
          for h, m in flatten(r["handle"], tuple(r.get("match", []))) if h.get("handler") != "subroute"]
check([h for h, _ in served].count("metrics") == 1 and all(not v.get("tls_connection_policies") for v in metrics.values()),
      f"the metrics server serves Caddy's metrics once, over plain HTTP {served}")
check(set(h for h, _ in served) <= {"metrics", "reverse_proxy", "rewrite"},
      f"the metrics server does nothing but serve metrics and proxy {sorted(set(h for h, _ in served))}")
proxied = {tuple(p for x in m for p in x.get("path", [])): dials(h) for v in metrics.values() for r in v.get("routes", [])
           for h, m in flatten(r["handle"], tuple(r.get("match", []))) if h.get("handler") == "reverse_proxy"}
check(set(proxied) == {("/authentik/server/metrics",), ("/authentik/worker/metrics",)}
      and all(len(d) == 1 and d[0].startswith("127.0.0.1:") for d in proxied.values()),
      f"it proxies only /authentik/server/metrics and /authentik/worker/metrics, each to a loopback listener {proxied}")
rewrites = [h.get("uri") for v in metrics.values() for r in v.get("routes", [])
            for h, _ in flatten(r["handle"]) if h.get("handler") == "rewrite"]
check(rewrites == ["/metrics", "/metrics"], f"each proxied path is rewritten to the listener's /metrics {rewrites}")
jobs = json.loads(P["prometheusConfig"])["scrape_configs"]
scraped = {j["job_name"]: (j.get("metrics_path", "/metrics"), t) for j in jobs
           if j["job_name"] in ("caddy", "authentik-server", "authentik-worker") for sc in j["static_configs"] for t in sc["targets"]}
check(scraped == {"caddy": ("/metrics", metrics_target), "authentik-server": ("/authentik/server/metrics", metrics_target),
                  "authentik-worker": ("/authentik/worker/metrics", metrics_target)}, f"black-pi scrapes all three {scraped}")
routes = {}
for server in servers.values():
    for route in server["routes"]:
        for match in route.get("match", []):
            for host in match.get("host", []):
                routes[host] = route
wildcard = "*.sammasak.dev"
fallback = routes.pop(wildcard, None)
check(fallback is not None and routes.pop("sammasak.dev", None) is fallback, "the apex shares the wildcard's route")
expected = {f"{name}.sammasak.dev" for name in [*backends, "herman"]}
check(set(routes) == expected, f"exactly the edge's names have a route {sorted(set(routes) ^ expected)}")
answer = [(h.get("handler"), h.get("status_code"), m) for h, m in flatten((fallback or {}).get("handle", []))
          if h.get("handler") != "subroute"]
check(answer == [("static_response", 404, ())], f"the apex and any other name under the wildcard are 404 {answer}")
order = [r for server in servers.values() for r in server["routes"]]
check(fallback is not None and order[-1] is fallback, "the wildcard route comes after every named one, so they win")

tls = config["apps"].get("tls", {})
check("automation" not in tls, f"Caddy issues no certificate of its own {tls.get('automation')}")
cert = P["cert"]
check(cert["extraDomainNames"] == ["*.sammasak.dev"], f"the ACME certificate is the wildcard {cert['extraDomainNames']}")
files = tls.get("certificates", {}).get("load_files", [])
loaded = [(f["certificate"], f["key"]) for f in files]
check(loaded == [(f"{cert['directory']}/cert.pem", f"{cert['directory']}/key.pem")],
      f"Caddy loads that certificate alone {loaded}")
tags = set(files[0].get("tags", [])) if len(files) == 1 else set()
policies = [p for server in servers.values() for p in server.get("tls_connection_policies", [])]
selecting = [p for p in policies if p != {}]
check(len(selecting) == 1 and set(selecting[0].get("match", {}).get("sni", [])) == expected | {wildcard, "sammasak.dev"}
      and set(selecting[0].get("certificate_selection", {}).get("any_tag", [])) == tags != set(),
      f"one TLS policy serves it for exactly the edge's names, the wildcard and the apex {selecting}")

for name, backend in backends.items():
    route = routes.get(f"{name}.sammasak.dev")
    if route is None:
        continue
    steps = list(flatten(route["handle"]))
    proxied = [i for i, (h, _) in enumerate(steps) if backend in dials(h) and not is_forward_auth(h)]
    check(len(proxied) == 1, f"{name} proxies to {backend}")
    if name in ("chat", "grafana"):
        auth = [i for i, (h, m) in enumerate(steps) if is_forward_auth(h) and m == ()]
        check(len(auth) == 1 and proxied and auth[0] < proxied[0],
              f"{name} runs forward_auth, unconditionally, before its backend")
        copies = [x.get("request", {}) for h, _ in steps if is_forward_auth(h) for r in h.get("handle_response", [])
                  for x, _ in flatten([y for rr in r["routes"] for y in rr["handle"]])]
        copied = {k for c in copies for k in c.get("set", {})}
        check(copied == headers, f"{name} copies the five X-Authentik-* fields {sorted(copied)}")
        for header in sorted(headers):
            deleted = [i for i, c in enumerate(copies) if header in c.get("delete", [])]
            setting = [i for i, c in enumerate(copies) if header in c.get("set", {})]
            check(len(deleted) == 1 and len(setting) == 1 and deleted[0] < setting[0],
                  f"{name} deletes a client-sent {header} before it sets the outpost's")
        check(all(dials(h) == [authentik] for h, _ in steps if authentik in dials(h)),
              f"{name}'s Authentik calls go to the native server alone")
        outpost = [m for h, m in steps if authentik in dials(h) and not is_forward_auth(h)]
        check(outpost == [({"path": ["/outpost.goauthentik.io/*"]},)],
              f"{name} sends only /outpost.goauthentik.io/* to Authentik besides forward_auth {outpost}")

steps = list(flatten(routes.get("otlp.sammasak.dev", {}).get("handle", [])))
allow = set(fleet.values())
denied = [m for h, m in steps if h.get("handler") == "static_response" and h.get("status_code") == 403]
ranges = [set(n["remote_ip"]["ranges"]) for m in denied for x in m for n in x.get("not", []) if "remote_ip" in n]
check(ranges == [allow], f"otlp answers 403 to any source but the fleet hosts {ranges}")
order = [h.get("handler") for h, _ in steps if h.get("handler") in ("static_response", "reverse_proxy")]
check(order == ["static_response", "reverse_proxy"], f"otlp checks the allowlist before it proxies {order}")

steps = list(flatten(routes.get("llm-gateway.sammasak.dev", {}).get("handle", [])))
gateway = [m for h, m in steps if "127.0.0.1:8081" in dials(h)]
check(gateway == [({"path": ["/v1", "/v1/*"]},)], f"llm-gateway proxies /v1 and /v1/* only {gateway}")
rest = [(h.get("status_code"), m) for h, m in steps if h.get("handler") == "static_response"]
check(rest == [(404, ())], f"everything else on llm-gateway is 404 {rest}")

check(P["chatStreams"] == ["/run/open-webui-edge.sock"], f"open-webui listens on Caddy's socket alone {P['chatStreams']}")

static = {
    "herman": (["/sw.js"], ["*.wasm", "*.js", "*.css", "/manifest.json", "/favicon.ico"]),
}
for name, (fresh, no_fallback) in static.items():
    steps = list(flatten(routes.get(f"{name}.sammasak.dev", {}).get("handle", [])))
    roots = [h.get("root") for h, _ in steps if h.get("handler") == "vars"]
    check(roots == [P["sites"][name]], f"{name}'s root is its Nix build {roots}")
    served = [h for h, _ in steps if h.get("handler") == "file_server"]
    check(len(served) == 1 and served[0].get("precompressed") == {"gzip": {}},
          f"{name} is served from files, with the .gz siblings {served}")
    check(not any(h.get("handler") == "reverse_proxy" for h, _ in steps), f"{name} proxies nowhere")
    hashed = {"path": ["*.wasm", "*.js", "*.css"], "not": [{"path": fresh}], "file": {}}
    cache = [(m, h["response"].get("require"), h["response"]["set"]["Cache-Control"]) for h, m in steps
             if h.get("handler") == "headers" and "Cache-Control" in h.get("response", {}).get("set", {})]
    check(cache == [((hashed,), None, ["public, max-age=31536000, immutable"]),
                    ((), {"headers": {"Cache-Control": None}}, ["no-cache"])],
          f"{name}: hashed wasm/js/css immutable, {fresh} and everything else no-cache {cache}")
    spa = [m for h, m in steps if h.get("handler") == "rewrite" and h.get("uri") == "/index.html"]
    check(spa == [({"not": [{"path": no_fallback}, {"file": {}}]},)],
          f"{name} falls back to /index.html only for a missing file outside {no_fallback} {spa}")

# DNS: every *.sammasak.dev name reaches this Caddy, dns.sammasak.dev reaches lenovo's AdGuard
answers = {r["domain"]: r["answer"] for r in P["rewrites"]}
check(answers.get("*.sammasak.dev") == fleet["acer-swift"], f"*.sammasak.dev answers acer's address {answers}")
check(answers.get("sammasak.dev") == fleet["acer-swift"], f"the apex answers acer's address {answers}")
check(answers.get("dns.sammasak.dev") == fleet["lenovo-21CB001PMX"], f"dns.sammasak.dev answers lenovo's address {answers}")

# every name Caddy serves has a blackbox probe from black-pi, so a new site cannot go unwatched
blackbox = [j for j in json.loads(P["prometheusConfig"])["scrape_configs"] if j["job_name"] == "blackbox"]
probed = {t.split("://", 1)[1].split("/", 1)[0] for j in blackbox for sc in j["static_configs"] for t in sc["targets"]}
unprobed = sorted(h for h in routes if h not in probed)
check(blackbox and not unprobed, f"black-pi probes every Caddy name (unprobed: {unprobed})")

sys.exit(1 if failed else 0)
