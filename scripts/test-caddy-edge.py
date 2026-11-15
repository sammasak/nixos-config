"""acer's Caddy edge (modules/homelab/edge.nix), as `caddy adapt` reads the deployed Caddyfile: the admin API is off,
every name has its route and backend, chat and grafana pass forward auth before their backend with the five
X-Authentik-* fields copied, otlp admits the fleet alone, and llm-gateway serves /v1 only."""
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

authentik = "10.43.238.182:80"
backends = {
    "auth": authentik,
    "chat": "unix//run/open-webui-edge.sock",
    "grafana": f"{fleet['black-pi']}:3000",
    "llm-gateway": "127.0.0.1:8081",
    "otlp": "127.0.0.1:4318",
    "ntfy": f"{fleet['lenovo-21CB001PMX']}:2586",
    "herman": "10.43.114.35:8080",
    "karta": "10.43.147.178:8080",
    "registry": "10.43.23.61:5000",
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


check(config.get("admin") == {"disabled": True}, f"the admin API is off {config.get('admin')}")
check(P["enableReload"] is False, "a config change restarts Caddy: reload needs the admin API")
check(P["failing"]["acer"] == [], f"acer fails no assertion {P['failing']['acer']}")
check(any("services.caddy" in m and "open-webui" in m for m in P["failing"]["noCaddy"]),
      f"the open-webui edge socket without Caddy is rejected {P['failing']['noCaddy']}")

servers = config["apps"]["http"]["servers"]
routes = {}
for server in servers.values():
    for route in server["routes"]:
        for match in route.get("match", []):
            for host in match.get("host", []):
                routes[host] = route
expected = {f"{name}.sammasak.dev" for name in backends}
check(set(routes) == expected, f"exactly the edge's names have a route {sorted(set(routes) ^ expected)}")

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
check(len(selecting) == 1 and set(selecting[0].get("match", {}).get("sni", [])) == expected
      and set(selecting[0].get("certificate_selection", {}).get("any_tag", [])) == tags != set(),
      f"one TLS policy serves it for exactly the edge's names {selecting}")

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
        outpost = [m for h, m in steps if authentik in dials(h) and not is_forward_auth(h)]
        check(outpost == [({"path": ["/outpost.goauthentik.io/*"]},)],
              f"{name} sends only /outpost.goauthentik.io/* to Authentik besides forward_auth {outpost}")

steps = list(flatten(routes.get("otlp.sammasak.dev", {}).get("handle", [])))
allow = {fleet[h] for h in ("lenovo-21CB001PMX", "acer-swift", "msi-ms7758", "black-pi")}
denied = [m for h, m in steps if h.get("handler") == "static_response" and h.get("status_code") == 403]
ranges = [set(n["remote_ip"]["ranges"]) for m in denied for x in m for n in x.get("not", []) if "remote_ip" in n]
check(ranges == [allow], f"otlp answers 403 to any source but the four fleet hosts {ranges}")
order = [h.get("handler") for h, _ in steps if h.get("handler") in ("static_response", "reverse_proxy")]
check(order == ["static_response", "reverse_proxy"], f"otlp checks the allowlist before it proxies {order}")

steps = list(flatten(routes.get("llm-gateway.sammasak.dev", {}).get("handle", [])))
gateway = [m for h, m in steps if "127.0.0.1:8081" in dials(h)]
check(gateway == [({"path": ["/v1", "/v1/*"]},)], f"llm-gateway proxies /v1 and /v1/* only {gateway}")
rest = [(h.get("status_code"), m) for h, m in steps if h.get("handler") == "static_response"]
check(rest == [(404, ())], f"everything else on llm-gateway is 404 {rest}")

sys.exit(1 if failed else 0)
