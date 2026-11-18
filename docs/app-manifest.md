# App manifest v1alpha1 and its admission

An app repository describes its deployment in a small typed manifest; nixos-config holds what the platform
approves for it (the grant). Admission checks both against the fleet before anything is built or deployed. This is
the contract of #559 (epic #557), written for the lane the #558 draft recommends: pinned GitOps composition first.

It is a schema and a check only. `lib/app-manifest/` is plain Nix over `lib`: no host, role or Home Manager module
imports it (roles and home modules are auto-discovered from their own directories, not from `lib/`), so no host's
toplevel depends on it. The flake check `app-manifest` (`flake-modules/app-manifest-check.nix`) is its one consumer.

## Files

| File | What it is |
|---|---|
| `lib/app-manifest/v1alpha1.nix` | The manifest an app repository supplies: intent only |
| `lib/app-manifest/grant.nix` | The platform's grant for one app: placement and permissions |
| `lib/app-manifest/admission.nix` | The registry (`apps`, `grants`) and the rules relating them to each other and the fleet |
| `lib/app-manifest/facts.nix` | The fleet facts admission reads |
| `lib/app-manifest/default.nix` | `facts` and `admit facts registry`: the granted capabilities per app, or every refusal |
| `lib/app-manifest/example/herman.nix` | herman's web shell as its repository would declare it |
| `lib/app-manifest/fixtures/` | One registry per case: valid ones admitted, invalid ones refused |
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
| `ingress.<label>.auth` | `authentik` or `public` | `<label>.sammasak.dev`; the label is a DNS label |
| `runtime.static.spa` | bool | A static site the edge serves from the package |
| `runtime.service` | `program`, `port`, `resources`, `secrets`, `state` | A process the platform's unit runs |
| `runtime.service.port` | 1024 to 65535 | |
| `runtime.service.resources` | `memoryMiB` 16 to 2048, `cpuPercent` 5 to 200, `tasks` 1 to 512 | Every ceiling is bounded by its type |
| `runtime.service.secrets.<sops name>.credential` | file name, default the name's last segment | Read from `$CREDENTIALS_DIRECTORY` |
| `runtime.service.state.<volume>.backup` | `none` or `daily` | A directory the platform owns; a host path cannot be named |

`runtime` is a tagged union: exactly one of `static` and `service`. There is no field for a store path, a host,
a host path, a user, a systemd directive, a capability, host networking, a SOPS recipient or a Caddy snippet, so a
manifest cannot ask for any of them.

## Grant (platform-approved)

`grants.<app>` lives in nixos-config, where the app's own CI cannot write, and is reviewed apart from the manifest:
`owner`, `repo`, `host` (one of `sam.fleet.hosts`), `hostnames`, `secrets` (sops names) and `memoryMiB` (the
ceiling, default 256). `admit` returns, per admitted app, what it gets: host, owner, `repo@rev#package`, its full
hostnames with their auth, and for a service its port, resources, secrets and volumes.

## Admission rules

Types refuse a malformed field on its own. The assertions relate fields to each other and to the fleet, each
naming the field it refuses:

- every app has a grant; its `owner` and `source.repo` are the grant's;
- an ingress label is in the grant's `hostnames`, is no name the edge already serves, and no other app claims it;
- a static site or an app with ingress is placed on `sam.fleet.edge`;
- a service's `memoryMiB` is within its grant; its port is no `sam.fleet.listeners` or `sam.fleet.public` port
  on its host, and no other app's port there;
- each secret is in the grant's `secrets` and is a sops secret declared on the app's host.

The facts come from `modules/core/fleet.nix` (hosts, listeners, public ports, the edge), evaluated with `lib` alone,
and from the hosts' evaluations in the flake check: the names the edge's Caddy serves and each host's
`sops.secrets` names. No network access and no app code is evaluated: a manifest is data.

A store path is never an input. The platform builds `packages.<system>.<package>` of the allowlisted repository at
the pinned rev, so an executor or registry never trusts a path a caller hands it.

## Running it

`python3 scripts/test-app-manifest.py [fixture ...]` evaluates each fixture with `nix-instantiate --eval` and
`<nixpkgs/lib>`, against `lib/app-manifest/fixtures/host-facts.json`, a hand-kept stub of the edge names and
secret names. The flake check runs the same script on the real facts. A new fixture needs its row in the script's
`CASES`: the expected outcome and the field its error must name.

## Versions

A field is added to v1alpha1 only with a default, so a manifest that passed still passes. A change that is not
additive is v1alpha2: a `v1alpha2.nix` next to `v1alpha1.nix`, with `apps` choosing the submodule by each
manifest's `apiVersion` and admission reading the fields both versions share. Both stay admitted until no app
declares v1alpha1; only then is it removed.

## Out of scope

No runtime: nothing renders a unit, a Caddy site or a sops declaration from a manifest yet, and no host imports
these files. No executor, no repository registration or bot (#560), no build or provenance pipeline (#561), no
ports bound only on loopback by modules outside `sam.fleet` (admission does not know them). herman keeps its
`edge.nix` site; the example uses `herman-next` because admission refuses `herman` while that site serves it.
