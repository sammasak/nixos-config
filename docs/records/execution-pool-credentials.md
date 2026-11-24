# Execution pool credentials: sidecars, not binds

Status: slice 1 proposed with this PR, for the owner to accept by merging. Issue 754, item 1: a session's home is
copied to the store on another host at every park, and only `home/.ssh/` is excluded, so any credential that is in a
slot guest can end up in the store. The fix is structural: a slot guest holds no credential, and every call out goes
through a host-side sidecar that holds the credential and adds it to the request. Background and the longer plan:
[credentials-and-tenancy.md](credentials-and-tenancy.md).

## What a slot can read or use today

From `modules/workers/{core,default,execution-pool}.nix`, `modules/homelab/exec-pool*.nix` and the hosts, before
this PR. "Home" is the session home, `/session/cur/home`, which a park copies to the store.

| Credential | Where it lives | How a slot uses it | Can it reach the home | Kind |
|---|---|---|---|---|
| Claude OAuth token (sops `claude_oauth_token`) | host, `dev-env-egress` LoadCredential | `anthropic.sock`; the guest has `CLAUDE_CODE_OAUTH_TOKEN=held-by-the-host` | no | sidecar |
| Pi project key (sops `llm_gateway_pi_key`, acer) | host, proxy credential | `llm-gateway.sock`; Pi's `models.json` holds a placeholder | no | sidecar |
| OpenAI key (`sam.workers.codexAuthFile`) | host, proxy credential | `openai.sock`; no pool host sets it, so no slot has the route | no | sidecar (unused) |
| OTLP token (sops `native_otlp_auth`) | host relay | none: slots have `telemetry = false` | no | sidecar (unused) |
| Owner's GitHub SSH key (host user's `~/.ssh/id_ed25519`, a key of the GitHub account) | bound read-only at `/var/lib/host-credentials/id_ed25519`, mode 0600 owned by the guest user, linked as the guest home's `~/.ssh/id_ed25519` | `git push` to the clone's ssh `pushurl`, and nix's fetch of the `git+ssh` inputs (factum, nix-audit, llm-gateway, rf-proto, herman, devenv-platform). It pushes to any branch of any repository of the account | **yes**: any process in the slot reads it and can write a copy into the home or the work tree | bind into guest (acer and msi slots) |
| gh token (acer user's `~/.config/gh/hosts.yml`) | host; pool slots do not get it (`credentials = [ "id_ed25519" ]`); no named worker remains (a1 retired) | none in a slot | no | not in slots |
| Nix access token (sops `nix_access_token`) | host `nix.conf` `!include`, root 0400; a guest imports no `core/sops.nix` | none: the guest's nix client fetches with its own config | no | host only |
| Queue login (`exec_pool_runner` password, peer role) | host runner unit, LoadCredential | none: the runner claims, the guest never talks to the queue | no | host only |
| Store sync login (host's `ssh_host_ed25519_key` to `exec-pool-sync`) | host helper `exec-pool-exec@` | none: the host moves the tree | no | host only |
| Environment sshd key (`/var/lib/workers/ssh_host_ed25519_key`) | bound read-only, root 0600 in the guest; slots are not `rootInGuest` | proves the guest to Herdr's ssh; no outward login | no (the slot user cannot read it) | bind, root only |
| Home Manager files relinked into the home (`exec-pool-relink`, `cp -rsTH`) | store links | config only: base URLs and `held-by-the-host` placeholders | links only, no secret | file in home, no secret |
| Agent state the agent writes (`.claude.json`, `.claude/`, `.pi/`, `.codex/`) | home | no login today: every agent is signed in through a placeholder | only if an agent runs a login (`claude login`, `gh auth login`), which writes a real token into the home | file in home, empty of secrets |

So the one credential a slot really holds is the owner's GitHub SSH key, on every acer and msi slot, and it is the
widest: the whole account, every branch.

## Target model

- A slot guest holds placeholders only. Its socket directory, `/run/dev-env-egress/<slot>`, bound read-only at
  `/run/egress`, is its identity to the host.
- Each outward service has a host-side sidecar on that socket that holds the credential, adds it to the request and
  narrows what it may be used for: Caddy today (`dev-env-egress`), stock tools later where Caddy cannot read the
  protocol.
- Nothing a slot can read is a credential, so whatever the park copies is safe by construction, not by an exclude list.

## Slices, smallest first

1. **acer: GitHub through the existing sidecar (this PR).** `sam.workers.executionPool.github.repos` sets each slot's
   `egress.github.repos`; acer lists nixos-config, skills, alert-bridge and the private inputs, and binds no key. Git
   reaches `github.sock` by `insteadOf` in the guest's system git config too, since a one-shot attempt's HOME has no
   Home Manager files and its push URL is ssh. The proxy signs git smart HTTP for listed repositories with acer's gh
   token, refuses repository administration and any repository not listed. Chosen first: it removes the widest
   credential from two slots with no new code or tool (the GitHub site, its tests and its doc exist; no instance used it).
2. **msi: the same.** msi has no GitHub token on the host, so it keeps the key until it has one: an owner decision, a
   gh login for `lukas` on msi (then `sam.workers.ghHostsFile`) or a sops token. Then no slot gets `id_ed25519`, and
   an assertion keeps it so.
3. **Push only `pool/<task id>`.** Caddy cannot read the ref updates in a receive-pack body. GitHub-native first: a
   ruleset on each listed repository's default branch (no deletion, no non-fast-forward, changes through a PR) is an
   owner action. Per-task refs need a ref-aware hop, for example a host-side bare repository per slot whose
   `pre-receive` hook admits `refs/heads/pool/*` and whose `post-receive` pushes upstream with the host's credential.
4. **Short-lived tokens.** A GitHub App installation token minted on the host per task (one hour, listed repositories,
   contents write) in place of the owner's gh token in the sidecar (credentials-and-tenancy.md, phase 4).

## Verification of slice 1, after the owner deploys acer

In an acer slot: `test ! -e /var/lib/host-credentials/id_ed25519`; a pool task pushes `pool/<task id>` and the runner
records it handed back; `nix flake metadata` in nixos-config fetches factum through the proxy;
`journalctl -u dev-env-egress` on acer shows the `github-pool1` requests. A task on a repository not listed fails its
push with 403: add the repository to the list.
