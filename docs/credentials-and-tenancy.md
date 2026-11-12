# Credentials for any tool, several users, and rented hosts

Research and plan, 2026-11-12. Nothing here is built. It answers three
questions about the environments in [nspawn-workers.md](nspawn-workers.md):

1. How does every tool and protocol use the host's credentials unless a rule
   blocks it, with no secret in the guest?
2. How does one host serve several users, each with their own credentials?
3. How does the same setup run on a VPS, declared like the home hosts?

Sources: the current module, read line by line; web research on proxies,
platforms and providers. Facts about other projects below come from their
docs as read on this date and are not tested here. Each one that the plan
depends on is listed under "To verify first".

## Where we are

The host proxy (`dev-env-egress`, Caddy on one socket directory per
environment) signs calls to Anthropic and GitHub. It works, and it has four
limits:

- **One hand-written site per service.** The service list is spelled three
  times in `modules/workers/default.nix`, with assertions and credential
  rules per service.
- **Only tools with a base-URL override.** Each tool is pointed at the proxy
  by its own setting. A tool with a fixed host and TLS cannot use it.
- **Allowlist.** GitHub is refused unless the repository is listed, and
  GraphQL is off, so `gh pr` and `gh issue` fail.
- **One user, this fleet.** The proxy is in the fleet adapter, runs as the
  one user, and holds every token.

## 1. Any tool, any protocol

### Four ways to keep a secret outside

Every protocol fits one of these. The plan is one declaration that picks a
mechanism per credential.

| Mechanism | What it is | Fits | Left exposed |
|---|---|---|---|
| A. Inject | The proxy adds the header on the way out | Any HTTPS API: Anthropic, GitHub, npm, crates.io, PyPI, registries, Google APIs | Use of the credential while the environment runs |
| B. Sign | The host signs, the key stays there | SSH (agent socket), commit signing, AWS (SigV4 at the proxy) | Anything that key is accepted for |
| C. Mint | The host makes a short-lived, narrow token | GitHub App tokens (1 h, per repo), Kubernetes TokenRequest, SSH certificates | The token until it expires, if it enters the guest |
| D. Gateway | A host service speaks the protocol and logs in upstream | Postgres and MySQL (pgbouncer), SMTP relay, `kubectl proxy`, a registry mirror | The rights of the upstream role |

Best is C then A: mint on the host and inject, so not even the short token
enters the guest.

Not solvable by any of these: a tool whose credential helper runs in the
guest (docker credential helpers, `credential_process`, kubectl exec plugins)
gets the secret by design. Those need mechanism A or D in front instead.

### One engine for HTTPS

"Any tool" needs a proxy that tools reach through `HTTPS_PROXY`, that opens
TLS with a certificate authority only that guest trusts, and that swaps a
placeholder for the real secret per destination. Every hosted agent platform
that was read does this (Anthropic, Vercel, Deno, Modal, E2B, OpenShell).

Guest side, declared once for every environment:

- `HTTPS_PROXY` to a loopback shim on the environment's socket, as today.
- The environment's CA in `security.pki.certificateFiles`, plus the variables
  for tools that skip the system bundle (`NODE_EXTRA_CA_CERTS`,
  `REQUESTS_CA_BUNDLE`, `CARGO_HTTP_CAINFO`, the nix-daemon's
  `NIX_SSL_CERT_FILE`).
- No route out except the proxy, so a tool that ignores the proxy fails
  closed. UDP 443 blocked so clients fall back from QUIC.
- Destinations with no credential pass through untouched (no interception).

Engine candidates:

| Engine | For | Against |
|---|---|---|
| `srt-proxy` from Anthropic's sandbox-runtime, plus a small decider of ours | Built as a boundary: asks a decider per request before dialling, pins Host to the CONNECT target, strips client credentials, refuses odd paths and TRACE; takes a listening socket, which is our per-environment model | v0.0.x research preview; Node; likely HTTP/1.1 only; websockets unknown; drops private ranges by default |
| mitmproxy plus a policy addon | Mature; HTTP/2 and websockets | A debugging tool: every safeguard above is ours to write; streaming needs care |
| NVIDIA OpenShell | Richest policy ready-made (REST and GraphQL deny rules, minting) | Weekly 0.1.x; built around its own sandbox; default is log-only |
| Caddy (today) | Already here, no CA in the guest | Cannot intercept; one config per tool |

Rejected: Squid (no HTTP/2), Envoy (heavy), Fly Tokenizer (clients must add
its header), Infisical Agent Vault (self-hosting deprecated).

**Choice: spike `srt-proxy` and mitmproxy side by side on msi, keep Caddy
until one wins.** Pass criteria: `claude`, `gh`, `git`, `nix`, `cargo`,
`npm` and `curl` work unchanged with only placeholder tokens; a streamed
Claude reply is not buffered; the leak check passes; the engine adds no
always-on memory worth counting against the pool.

### Default allow

The owner's rule: the host's credential is used unless we blocked it.

- **Per credential, `default = "allow"` with deny rules.** The repository
  list becomes optional narrowing, not a requirement.
- **GitHub REST deny list** (today's, extended): repository delete, transfer
  and settings; collaborators and invitations; deploy keys, user keys and
  signing keys; hooks; branch protection and rulesets; Actions secrets,
  variables, runner tokens and permissions; `/app`, `/installation`,
  `/authorizations`; organisation writes.
- **GraphQL on, filtered.** `gh` sends GraphQL for nearly every `pr`, `issue`
  and `repo` command. Path rules cannot see inside it, so the decider parses
  the body and decides on operation type and top-level field names (never the
  client-chosen operation name). Deny mutations matching the same classes as
  the REST list; deny batched documents with any denied operation.
- **Pushes.** The decider reads the ref updates at the start of a push and
  can deny deletions, tags and protected branches. Force pushes are not
  visible there; a GitHub ruleset on the branch is the control.
- **Responses that carry credentials** are denied or stripped: runner
  registration tokens, installation token endpoints, OAuth refresh.
- **The real bound is on GitHub's side.** A deny list will miss something. A
  GitHub App installed on chosen repositories, without administration,
  workflows, secrets or members permission, caps the worst case whatever the
  proxy lets through. Today's token is the owner's full `gh` login.

Until the engine exists, default allow can only be approximated on Caddy:
any repository, REST deny list, GraphQL on and unfiltered. That lets a guest
change branch protection through GraphQL with the owner's token, so it is
not offered as a default. Per environment it is already one option
(`egress.github.graphql = true`).

### What a default-allow proxy does not stop

A compromised guest can use every credential for anything not denied, and
can move data out through allowed channels (a gist, an issue comment, the
Claude API). It cannot take the credential away. Controls that remain: one
minted token per environment so GitHub's audit log names it, a request log
on the host (method, host, path, GraphQL fields, verdict; never bodies), and
a rate limit per credential.

### Declaration

The module seam first, independent of the engine: the proxy moves from the
fleet adapter into the generic module, and services become data.

```nix
services.devEnvironments.credentials.github = {
  secret = { path = "/run/secrets/gh-app.pem"; kind = "github-app"; };  # or "file", "gh-hosts"
  hosts = [ "github.com" "api.github.com" "codeload.github.com" ];
  inject = { header = "Authorization"; format = "token {}"; };
  default = "allow";
  deny = [ { path = "/repos/*/*/keys/**"; } { graphql = "delete*"; } { push = "refs/tags/*"; } ];
  guest.env.GH_TOKEN = "held-by-the-host";
};
instances.<name>.credentials = [ "github" "anthropic" ];   # which ones this environment may use
```

Other mechanisms use the same entry with a different delivery: `sign` (an
agent socket), `gateway` (a host unit and a guest socket). What stays code:
reading gh's `hosts.yml`, minting, the GraphQL and push parsers.

This deletes from the adapter: the three copies of the service list, three
Caddy snippets, three per-service assertions, the credential subtraction
rule and the `hosts.yml` watcher.

## 2. Several users on one host

### What blocks it today

One user is assumed throughout: one uid, one state directory, one shared SSH
host key and Nix cache directory, one memory pool, one proxy unit holding
every token, one Herdr session.

### Model

Environments nest under their owner, so an environment cannot name another
user's credentials.

```nix
services.devEnvironments.users.alice = {
  sshKeys = [ ... ];                  # the only keys her environments accept
  pool.memory = "6G";                 # her slice, a child of the host pool
  credentials = { github = { ... }; anthropic = { ... }; };
  instances.work = { credentials = [ "github" "anthropic" ]; };
};
```

- **Access.** A user reaches their environments by SSH into the guest only.
  No host shell, no `machinectl`. Instance names stay unique per host.
- **Credentials.** One proxy unit per user, running as its own system user,
  with that user's secrets and sockets bound only into that user's
  environments. sops recipients decide who can decrypt in git; on the host
  the separation is the unit and file ownership.
- **Resources.** `environments-<user>.slice` under the host pool, equal CPU
  weight per user, the burst rule inside each. Disk: a quota per state
  directory (XFS project quota or a ZFS dataset); the shared store is not
  covered.
- **State.** Per user: state directory, Nix cache directory, SSH host key.
- **Each user brings their own Anthropic login.** Sharing one subscription
  between people is likely against its terms: owner to check.

### The store and daemon decide who may be a tenant

The whole store is readable by every guest, and the daemon socket in a guest
is a root-level attack surface with a serious bug about once a year (the
last, CVE-2026-39860, is fixed in 2.34.5; the hosts run 2.34.9). So:

| Tenant | Nix access | Isolation |
|---|---|---|
| The owner's own environments | Host daemon (today) | nspawn |
| People the owner trusts | No daemon socket: read-only store, environments prebuilt from the declaration | nspawn |
| Anyone else | Own daemon and store | A microVM per user (microvm.nix, read-only virtiofs store share); needs KVM |

The per-tenant overlay store was looked at and set aside: experimental, and
it requires a lower store that never changes, which a live host store does.

## 3. Rented hosts

### What a fresh NixOS host needs

The generic module evaluates on a bare host today. Missing for a VPS:

- **The proxy in the generic module** (section 1). Without it the only way to
  give a guest a credential is to bind it in.
- **Blocked networks set.** The default is empty, so guests would reach the
  provider's metadata address and private network. The VPS profile sets the
  link-local and private ranges.
- **A profile that is not the home role.** The home role pulls in LAN cache
  addresses, k3s timing and fleet secrets. A VPS imports the generic module,
  a deploy-rs node and its own small profile.

### Install and deploy

- nixos-anywhere with disko for the install (needs 1.5 GB RAM for kexec);
  the host SSH key is generated beforehand and passed in, so its age key is
  in `.sops.yaml` before first boot.
- deploy-rs push from lenovo, as for the home hosts. The closure is built at
  home and copied, so the VPS never evaluates or builds its system.
- WireGuard or Tailscale only; SSH listens on the tunnel. Provider firewall
  as the second layer.
- Disk encryption with unlock over SSH in the initrd protects disks and
  snapshots at rest, not a running machine, and needs an unlock per reboot.

### Secrets on rented hardware

The provider can read memory and disk. "Secrets stay on the host" then means
they sit with the provider. Ranked:

1. **Broker at home.** The VPS proxy forwards over the tunnel to a broker on
   a home host, which injects and calls upstream. The VPS holds nothing
   long-lived. Cost: home uplink and availability.
2. **Short-lived tokens pushed to the VPS.** Works for GitHub App tokens.
   The Claude token lasts a year and cannot be shortened, so it either goes
   through the home broker or is accepted as exposed.
3. **Confidential VM** (GCP, Azure). Several times the price, and only worth
   it with attestation, which is real work on NixOS.

### Size and provider

About 2 GiB reserved per environment plus 2 to 3 GiB for the host: 8 GB for
two or three environments, 16 GB for four to six. Hetzner Cloud has no nested
KVM, so the microVM tier needs bare metal; an auction server with 64 GB is
likely the best value. Prices move; check at order time.

## Phases

Each ends with a check; none needs the next.

1. **Seam.** Proxy into the generic module, services as data, today's two
   services reproduced, tests unchanged in what they assert. No behaviour
   change. Unblocks everything else.
2. **Engine spike on msi.** `srt-proxy` and mitmproxy against the pass
   criteria above. Decide, or stay on Caddy.
3. **Default allow for GitHub.** Decider with the REST list, GraphQL and push
   parsing; `gh pr create` and `gh issue comment` work in a guest, the deny
   list is refused, leak check passes.
4. **GitHub App tokens** minted per environment on the host (nixos-config
   #166). Owner gate.
5. **Owner split.** `users.<name>` with per-user slice, state, proxy unit
   and keys; the current single user becomes the first entry. Checked with a
   second local user whose environment cannot reach the first's sockets.
6. **VPS profile.** One rented host installed with nixos-anywhere, deployed
   from lenovo, credentials through the home broker. Owner gate (money).
7. **More mechanisms as needed:** SSH agent socket, a database gateway, a
   mail relay. Built when an environment needs one.

## Owner decisions

- Create the GitHub App and its permission set (new privileged credential).
- Who may be a tenant: only the owner, trusted people, or anyone. This
  decides whether the microVM tier is ever built.
- Whether trusted users may have the host daemon socket.
- Whether each user must bring their own Anthropic account.
- Which secrets may sit on rented hardware; provider and spend.
- Manual unlock per VPS reboot, or not encrypting.

## To verify first

Read, not tested:

- `srt-proxy` exists as described (listening socket, decider protocol), and
  how it handles websockets and HTTP/2.
- That Claude Code's streaming works through an intercepting proxy with a
  placeholder token, and which of `nix`, `cargo`, `uv` need extra CA
  settings in a NixOS guest.
- GitHub's GraphQL mutation names for the deny classes.
- Provider facts (nested KVM, prices, RAM for kexec).
- Whether a guest's `resolv.conf` works on a VPS that uses the resolved stub.
