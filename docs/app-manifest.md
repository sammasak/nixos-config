# App manifest v1alpha1 and its admission

An app repository describes its deployment in a small typed manifest; nixos-config holds what the platform
approves for it (the grant). Admission checks both against the fleet before anything is built or deployed. This is
the contract of #559 (epic #557), written for the lane the #558 draft recommends: pinned GitOps composition first.

It is a schema, a renderer and a check only. `lib/app-manifest/` is plain Nix over `lib`: no host, role or Home Manager module
imports it (roles and home modules are auto-discovered from their own directories, not from `lib/`), so no host's
toplevel depends on it. The flake check `app-manifest` (`flake-modules/app-manifest-check.nix`) is its one consumer.

## Files

| File | What it is |
|---|---|
| `lib/app-manifest/v1alpha1.nix` | The manifest an app repository supplies: intent only |
| `lib/app-manifest/grant.nix` | The platform's grant for one app: placement and permissions |
| `lib/app-manifest/admission.nix` | The registry (`apps`, `grants`) and the rules relating them to each other and the fleet |
| `lib/app-manifest/facts.nix` | The fleet facts admission reads |
| `lib/app-manifest/default.nix` | `facts`, `admit facts registry` (the granted capabilities per app, or every refusal) and `render` |
| `lib/app-manifest/render.nix` | The edge sites and the Prometheus scrape of the admitted apps |
| `lib/app-manifest/example/herman.nix` | herman's web shell as its repository would declare it |
| `lib/app-manifest/fixtures/` | One registry per case: valid ones admitted, invalid ones refused |
| `lib/app-manifest/golden/` | Each valid fixture's rendered Caddyfile and Prometheus config, byte for byte |
| `scripts/test-app-manifest.py` | Evaluates each fixture and checks the outcome and the field the error names |

## Manifest (developer-supplied)

Every submodule is closed: a field the schema does not know fails as ``The option `apps.<app>.<field>' does not
exist``. Collections are attribute sets keyed by name, so a duplicate inside one manifest cannot be written.

| Field | Type | Notes |
|---|---|---|
| `apiVersion` | `"v1alpha1"` | Selects the schema |
| `owner` | GitHub login, required | Must equal the grant's `owner` |
| `environment` | `production` or `staging` | |
| `source.repo` | `owner/name` | Must equal the grant's `repo`, the allowlist entry |
| `source.rev` | 40 hex characters | A branch, tag or short hash is refused |
| `source.package` | attribute name, default `default` | Built as the repository flake's `packages.<system>.<package>` |
| `health.path` | absolute HTTP path | Answers 2xx once the app serves |
| `ingress.<label>.auth` | `authentik` or `public` | `<label>.sammasak.dev`; the label is a DNS label; `public` only with the grant's `public` |
| `runtime.static.spa` | bool | A static site the edge serves from the package |
| `runtime.service` | `program`, `resources`, `secrets`, `state` | A process the platform's unit runs; it serves HTTP on its socket (below) |
| `runtime.service.metricsPath` | absolute HTTP path or null (default) | Where it serves Prometheus metrics on its socket; null: not scraped |
| `runtime.service.resources` | `memoryMiB` 16 to 2048, `cpuPercent` 5 to 200, `tasks` 1 to 512 | Every ceiling is bounded by its type |
| `runtime.service.secrets.<sops name>.credential` | file name, default the name's last segment | Read from `$CREDENTIALS_DIRECTORY` |
| `runtime.service.state.<volume>.backup` | `none` or `daily` | A directory the platform owns; a host path cannot be named |

`runtime` is a tagged union: exactly one of `static` and `service`. There is no field for a store path, a host,
a host path, a user, a systemd directive, a capability, host networking, a SOPS recipient or a Caddy snippet, so a
manifest cannot ask for any of them.

### The socket, not a port

A service has no port field: `runtime.service.port` fails as ``The option `apps.<app>.runtime.service.port' does
not exist``. It serves HTTP on the unix socket `/run/apps/<app>/http.sock`, a path the platform derives from the
app name (`socket` in `lib/app-manifest/default.nix`), and the edge's site and metrics handle proxy only to that.
So no manifest can aim the edge at another listener, such as acer's keyless llm-gateway on `127.0.0.1:11435`,
Authentik's `9000`/`9443` or alloy's `4318`, which no `sam.fleet` fact lists; and two apps cannot share an upstream,
since app names are unique keys. #559 asks for "entrypoint/port or socket"; #563 for "Unix sockets or loopback-bound
ports". `/run/apps/<app>` is what the runtime unit's `RuntimeDirectory=apps/<app>` creates and removes with the
unit; the app name pattern bounds the path to 51 bytes, within the 108 of `sun_path`.

An app that can only listen on TCP is out of scope here. The runtime ticket could bridge it with
`systemd-socket-proxyd` (shipped with systemd, so no new daemon class): a socket unit on the app's path in front of
a loopback port that only that app's unit uses.

## Grant (platform-approved)

`grants.<app>` lives in nixos-config, where the app's own CI cannot write, and is reviewed apart from the manifest:
`owner`, `repo`, `host` (one of `sam.fleet.hosts`), `hostnames`, `public` (whether its names may skip forward auth,
default false), `secrets` (sops names) and `memoryMiB` (the ceiling, default 256). `admit` returns, per admitted app, what it gets: host, owner, `repo@rev#package`, its full
hostnames with their auth, and for a service its socket, resources, secrets and volumes.

## Admission rules

Types refuse a malformed field on its own. The assertions relate fields to each other and to the fleet, each
naming the field it refuses:

- every app has a grant; its `owner` and `source.repo` are the grant's;
- an ingress label is in the grant's `hostnames`, is no name the edge already serves, and no other app claims it;
- a `public` label needs the grant's `public`; any other auth needs the edge to define a snippet of that name
  (`authentik`: the `(authentik)` forward_auth snippet in `modules/homelab/edge.nix`);
- a static site or an app with ingress is placed on `sam.fleet.edge`;
- a service's `memoryMiB` is within its grant; a service with a `metricsPath` is placed on the edge;
- each secret is in the grant's `secrets` and is a sops secret declared on the app's host.

The facts come from `modules/core/fleet.nix` (hosts, the edge and its metrics site), evaluated with `lib` alone,
and from the hosts' evaluations in the flake check: the names the edge's Caddy serves, the snippets its
`extraConfig` defines (`forwardAuth`) and each host's `sops.secrets` names. No network access and no app code is evaluated: a manifest is data.

A store path is never an input. The platform builds `packages.<system>.<package>` of the allowlisted repository at
the pinned rev, so an executor or registry never trusts a path a caller hands it.

## Rendering: edge sites and metrics scrape (not live)

`render facts registry package` turns `admit`'s output into what the edge and Prometheus would need; `package`
maps an app name to its built store path (the check uses a fixed stand-in). Nothing imports it yet: acer's Caddyfile
and black-pi's Prometheus config do not change.

- `virtualHosts`: one `services.caddy.virtualHosts` entry per ingress name, shaped as `edge.nix`'s (`useACMEHost`
  the domain). The site is a `route`, so its order holds: for an auth other than `public` first `import <auth>`,
  the edge's own snippet (the one chat and grafana import, not a copy), then a service's `reverse_proxy
  unix//run/apps/<app>/http.sock`, or a static site's `root * <package>`, `try_files {path} /index.html` for an SPA, and
  `file_server`.
- `metricsHandles`: per scraped app a `handle /apps/<app>/metrics` that rewrites to its `metricsPath` and proxies
  to its socket, for the edge's plain-HTTP metrics site (`sam.fleet.edgeMetrics`), beside Authentik's loopback
  metrics; no app port is opened in the firewall.
- `scrapeConfigs`: one `scrape_configs` entry, job `apps`, one target per app with a `metricsPath`, at the edge's
  metrics address with `__metrics_path__` `/apps/<app>/metrics` and the labels `app`, `owner` and `node` (the
  grant's host); `sample_limit` 10000, since the app decides its series.

Every value written into the Caddyfile is typed: the app name and labels by their patterns (the socket path is derived from the name),
`metricsPath` by an absolute path pattern without space, brace, quote, query or empty segment (so no leading `//`
authority), the auth by its enum, the package by
a store-path match (`render` throws otherwise). A manifest has no free-text field that reaches the Caddyfile, so a
snippet cannot be written; the fixtures `caddy-injection`, `metrics-path-relative` and `metrics-via-loopback` show the type refusing. No
TCP upstream is rendered: nothing creates the socket until the runtime unit exists, as nothing listened on a port.

The check compares each valid fixture's rendered Caddyfile (the sites, then the metrics site) and Prometheus
config with `lib/app-manifest/golden/`, then runs `caddy validate` on the edge's own snippet text (acer's evaluated
`services.caddy.extraConfig`) followed by the sites, and `promtool check config` on the scrape. A change to the
rendering updates the golden files in the same commit.

## Running it

`python3 scripts/test-app-manifest.py [fixture ...]` evaluates each fixture with `nix-instantiate --eval` and
`<nixpkgs/lib>`, against `lib/app-manifest/fixtures/host-facts.json`, a hand-kept stub of the edge names, its
snippet names and secret names. Without `--caddy`, `--promtool` and `--edge-snippets` it prints `UNCHECKED` for the
validation, not a pass. The flake check runs the same script on the real facts, with all three. A new fixture needs its row in the script's
`CASES`: the expected outcome and the field its error must name.

## Versions

A field is added to v1alpha1 only with a default, so a manifest that passed still passes. A change that is not
additive is v1alpha2: a `v1alpha2.nix` next to `v1alpha1.nix`, with `apps` choosing the submodule by each
manifest's `apiVersion` and admission reading the fields both versions share. Both stay admitted until no app
declares v1alpha1; only then is it removed.

## Dry-run bump

`python3 scripts/app-bump-dry-run.py --registry FILE [--flake DIR] [--json]` prints, per registered app, the pin PR
its repository's green `main` would get. It is the first slice of #560 and decides nothing about #558's lane.

- **Reads:** the registry as JSON (`grants.<app>` and `apps.<app>.source`, the config admission declares,
  evaluated elsewhere: it evaluates no Nix), `flake.nix` and `flake.lock`, and GitHub through read-only `gh api`.
  The app's flake input is named after the app and pinned `git+ssh://git@github.com/<repo>?rev=<rev>`, as herman's.
- **Green:** walking `main` newest first, the first commit with at least one successful check, every check run
  completed and successful, neutral or skipped, and its combined status success when it has statuses. Every check
  counts as required: a private repository on GitHub's free plan cannot read branch protection. A red, pending or
  unchecked commit is skipped, never pinned; the green commit must descend from the pin (GitHub's compare). herman has
  no checks today, so it reports `no-green` until its CI exists (#561).
- **Prints:** `bump` with the `flake.nix` line, the `flake.lock` node's `rev`, `lastModified` (the commit time),
  `revCount` and `original.rev`, and the PR's title and body (commit, old and new rev, compare URL, skipped commits,
  the grant); `nothing-to-bump` when the pin is main's newest green commit, so a replay is an empty diff; or
  `no-green`. `narHash` needs a fetch, so it is printed as pending, for `nix flake lock` on a gate host.
- **Refuses** (exit 2, naming the field, before any GitHub read): an app without a grant, a repo outside its grant
  (admission's own message), a rev that is not 40 hex, and a `flake.nix` or `flake.lock` pin that disagrees with the
  registry; the patterns are `names.nix`'s and `v1alpha1.nix`'s, verbatim.
- **Never:** writes a file, opens a PR, needs a token beyond gh's own read, runs a timer, or touches a host.

`scripts/test-app-bump-dry-run.py` runs it on a fake GitHub, without network or Nix.

## App registry and bump (lane 1)

`apps/registry.json` holds, per app, its grant and `source` (`repo`, `rev`, `narHash`); `lib/app-manifest/pins.nix`
type-checks the whole file on any use (names, the grant's repo allowlist and host, 40-hex rev, SRI `sha256-` narHash;
an unknown field fails) and `src APP` fetches the tree with `builtins.fetchTree` by rev and narHash, so a bad entry
or a hash that does not match the rev fails evaluation, never a deploy. The tree and its store path are the ones a
flake input at that rev gives. alert-bridge is on it (the overlay's `alertBridge` src); the other apps stay flake
inputs. `scripts/test-app-registry.py` (in the `app-manifest` flake check) evaluates the live file and bent copies.

`scripts/app-bump.py APP` runs the dry run's `green_after` on the registry entry, prefetches the new rev's narHash,
rewrites only that entry on `app-bump/APP-<sha12>` cut from origin/main, commits, pushes (the pre-push gate runs) and
opens the PR with the dry run's text. It refuses lenovo and a dirty checkout; `--dry-run` stops after the prefetch.
`scripts/test-app-bump.py` runs it on stubs.

## Out of scope

No runtime: nothing renders a unit or a sops declaration from a manifest yet, the rendered sites and scrape are
consumed by no host, and no host imports these files but pins.nix. No health probe or alert is rendered from `health.path` yet. No executor, no bot or timer (#560: the bump above is run by hand), no build or provenance pipeline (#561), no
TCP-only app bridge (above). herman keeps its
`edge.nix` site; the example uses `herman-next` because admission refuses `herman` while that site serves it.
