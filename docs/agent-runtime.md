# Agent runtime templates (M0: typed module, manifests, runtime adapter)

Epic: [nixos-config#133](https://github.com/sammasak/nixos-config/issues/133). This milestone
delivers the declarative half only: a reusable NixOS module that types what an ephemeral
`systemd-nspawn` agent instance would contain, and a versioned manifest per template. Nothing
in this module starts a container, adds a service, or touches a live host; the nspawn proof
(#135), source materialization (#136), security and admission (#137) and lifecycle (#138)
consume the manifest.

Terms: a **template** is a declaration under `sam.agentRuntime.templates.<name>`. A
**source** is one of its `repositories.<name>` entries (emitted under `sources` in the
manifest); the skills tree is the separate skills source. An **instance** is one ephemeral
container made from a template; one instance serves one **run**, the execution of one
**assignment** (the task handed to the run). A source with `resolve = "assignment"` is
resolved to a revision when the run receives its assignment (#136), not from `flake.lock`. The **template manifest**
(this milestone) describes the template; the **run manifest** (#136, #138) records what one
run resolved and did. Options exist only where an issue in this epic names a consumer.

## Using it from another flake

```nix
inputs = {
  nixos-config.url = "github:sammasak/nixos-config";
  factum = { url = "github:sammasak/factum"; flake = false; };   # a source repo (this flake pins it over git+ssh)
  skills = { url = "github:sammasak/skills"; flake = false; };   # the skills tree
};
```

In a host, import the module and declare `sam.agentRuntime` as below. Without a host, the
standalone evaluator returns `sam.agentRuntime` with `manifestData` and `manifestDir` filled
in, or throws the failed checks:

```nix
imports = [ inputs.nixos-config.nixosModules.agent-runtime ];                  # in a host

runtime = (inputs.nixos-config.lib.agentRuntime { inherit pkgs; }).evalManifests {
  modules = [ ./templates.nix ];                     # without one: runtime.manifestDir etc.
};
```

The reference consumer is `tests/agent-runtime/flake.nix` (templates `rust-worker` and
`docs-reviewer`, a read-only reviewer whose role is `quality`).

| Output | What |
|---|---|
| `nixosModules.agent-runtime` | the NixOS module; options under `sam.agentRuntime` |
| `lib.agentRuntime { pkgs }` | `evalManifests { modules }`, the standalone evaluator above |
| `packages.x86_64-linux.agent-runtime-options` | option reference (CommonMark) generated from the module |
| `packages.x86_64-linux.agent-runtime-manifests` | the example templates' manifests, one `<name>.json` per template |
| `checks.x86_64-linux.agent-runtime-eval` | the example manifests build and pass a shape check; every negative case fails evaluation |

## Options

The generated reference (`nix build .#agent-runtime-options`) is authoritative. The shape is
below; `x ? d` means the field defaults to `d`, and every other field is required (notably
`skillsSource`, each private mount's `sizeMiB`, and `cpus`, `memoryMiB`, `timeoutMinutes`):

- `sam.agentRuntime.templates.<name>`: a description of possible instances; the name, like
  every repository name and `role.name`, is a label: lowercase letters, digits and `-`,
  starting and ending with a letter or digit, at most 63 characters.
  - `role = { name; harness = "claude-code" | "codex" | "pi"; }`
  - `repositories ? { }`, each `<name> = { github = "owner/repo"; ref = { type = "branch" |
    "tag" | "commit"; value; }; resolve ? "lock"; lock ? null; path; writable ? false; access ?
    "public"; }` with `lock = inputs.<input>`; `access = "private"` makes an assignment-time
    prefetch require `GH_TOKEN` and fail closed without it
  - `skillsSource = inputs.skills;` and `skills ? { }`, each `<skill-dir-name> = { }`
  - `packages ? [ ]`, as `with pkgs; [ ... ]`
  - `filesystem`: `workspace ? "/workspace"` (parent of every repository path); the private
    mounts `home` (`/home/agent`), `tmp` (`/tmp`), `cache` (`/var/cache/agent`), `output`
    (`/output`), each `{ path ? <that default>; sizeMiB; inodes ? 100000; }`; and
    `mounts ? [ ]`, each `{ hostPath; path; writable ? false; }`, host bind mounts restricted
    by `host.allowedMountRoots`
  - `resources = { cpus; memoryMiB; tasksMax ? 512; timeoutMinutes; }`
  - `network.allow ? null`: `null` is no egress; a non-empty list of DNS names is the egress
    allowlist
  - `capabilities ? [ ]`: a subset of `github-read`, `github-comment`, `github-push`. A
    writable checkout never implies `github-push`.
- `sam.agentRuntime.host`, host policy separate from templates: `enable ? false` (must be
  true before any template is eligible; it starts nothing), `eligibleTemplates ? [ ]`,
  `maxConcurrentInstances ? 1`, `reserve.{memoryMiB ? 2048, diskMiB ? 10240}`,
  `allowedMountRoots ? [ ]` (so no host mount is allowed by default; a string is a read-only
  root, `{ path; writable = true; }` lets templates bind it read-write; each path once; the
  most specific covering root decides).
- Results: `manifestData.<name>` (attrset) and `manifestDir` (`<name>.json` files).

## Example: a Rust worker

The fixture `tests/agent-runtime/templates.nix` is the full `rust-worker` template (role
`rust-worker` on `claude-code`, skills `rust-engineering` and `nix-flake-development`,
`cargo rustc gcc git`, budgeted mounts, allowlisted egress, `github-read` and
`github-comment`). Its three checkouts of one real Rust repo show every ref form; `factum`
and `skills` are flake inputs with `flake = false`, so `rev`, `narHash` and `outPath` come
from `flake.lock`:

```nix
repositories = {
  factum = {                                    # a branch, locked by the flake input
    github = "sammasak/factum";
    ref = { type = "branch"; value = "main"; };
    lock = inputs.factum;
    path = "/workspace/factum";
    writable = true;                            # a private copy; never push rights
  };
  factum-pinned = {                             # an exact commit; lock.rev must equal it
    github = "sammasak/factum";
    ref = { type = "commit"; value = inputs.factum.rev; };
    lock = inputs.factum;
    path = "/workspace/factum-pinned";
  };
  factum-release = {                            # a tag, resolved once per run (#136)
    github = "sammasak/factum";
    ref = { type = "tag"; value = "v0.2.0"; };
    resolve = "assignment";
    path = "/workspace/factum-release";
  };
};
skillsSource = inputs.skills;
skills = { rust-engineering = { }; nix-flake-development = { }; };
```

The ref rule, by `ref.type` and `resolve`:

| `ref.type` | `resolve = "lock"` (default) | `resolve = "assignment"` |
|---|---|---|
| `branch`, `tag` | `lock` required; `lock.rev` is the identity, `ref.value` the label it was taken at (not verified against the input) | `lock` forbidden; the run resolves the ref once (#136) |
| `commit` | `lock` required and `lock.rev` must equal the commit (the lock carries the content identity) | refused (a commit needs no resolution) |

No evaluation fetches anything: every revision comes from a locked input or is left to the run.

## Validation

Each of the cases in `tests/agent-runtime/cases.nix` fails evaluation (no manifest is produced)
with a message that names the option; the flake check confirms each fails, and
`nixos:agent-runtime-test` also matches each message. What is refused:

- refs: a `ref.type` outside `branch | tag | commit`; under `resolve = "lock"`, any ref without
  `lock`; under `resolve = "assignment"`, a branch or tag with `lock`, or any commit; a commit
  whose `lock.rev` differs from it; a ref name outside letters, digits and `._/-`, or one git
  would reject (a leading `-`, a component starting with `.` or ending in `.` or `.lock`, `..`,
  `//`).
- sources: the same `github` + ref twice; a repository without `path`; a path outside or equal
  to `filesystem.workspace`; a `lock.outPath` that is a path literal (it would copy into the
  store); a template or repository name that is not lowercase letters, digits and `-`.
- paths: any two of repository paths, private mounts, host-mount targets and the workspace
  equal or nested (a repository under the workspace is the one allowed pair); a path on, or
  containing, a root the runtime owns inside the instance (`/nix`, `/etc`, `/proc`, `/sys`,
  `/dev`, `/run`, `/var/run`, `/usr`, `/bin`, `/lib`, `/lib64`, `/sbin`, `/boot`, `/root`,
  `/var/lib`); a path with `.`/`..`, `//`, a trailing slash, or characters outside
  `[A-Za-z0-9._-]`.
- skills: a name without `<skillsSource>/skills/<name>/SKILL.md` (the message lists the known
  names), including any name with `/`.
- policy: a value of the wrong type or shape (`memoryMiB = "4G"`, an IP literal, a single-label
  name or a name over 253 characters or with a label over 63 in `allow`, an empty `allow` list,
  an unknown harness or capability, a `github` that is not `owner/repo`, a `lock.rev` that is
  not 40 hex or a `lock.narHash` that is not a sha256 SRI hash).
- host: a mount whose `hostPath` is under no allowed root, or bound read-write under a
  read-only root (the most specific covering root decides); an allowed root declared twice;
  an allowed root on, or containing, host state no template may reach (`/nix`, `/etc`,
  `/proc`, `/sys`, `/dev`, `/run`, `/var/run`, `/var/lib`, `/var/tmp`, `/var/log`, `/usr`,
  `/tmp`, `/boot`, `/root`, `/home`: the instance list plus the world-writable, log and
  user directories a host exposes); `eligibleTemplates` naming no template, or set while
  `host.enable` is false.

## Manifest (`agent-runtime-template`, schemaVersion 1)

Generated from the evaluated declaration; JSON is output, never input. Abbreviated:

```json
{
  "schemaVersion": 1, "kind": "agent-runtime-template",
  "template": { "name": "rust-worker" },
  "role": { "name": "rust-worker", "harness": "claude-code" },
  "sources": {
    "factum": { "github": "sammasak/factum", "ref": { "type": "branch", "value": "main" },
      "resolve": "lock", "path": "/workspace/factum", "writable": true,
      "locked": { "rev": "<40 hex>", "narHash": "sha256-...", "storePath": "/nix/store/...-source" } },
    "factum-release": { "...": "...", "resolve": "assignment", "locked": null }
  },
  "skills": {
    "source": { "rev": "<40 hex>", "narHash": "sha256-...", "storePath": "/nix/store/...-source" },
    "names": { "rust-engineering": { "path": "/nix/store/...-source/skills/rust-engineering" } }
  },
  "packages": [ { "name": "cargo", "storePath": "/nix/store/...-cargo-..." } ],
  "filesystem": { "workspace": "/workspace",
    "home": { "path": "/home/agent", "sizeMiB": 512, "inodes": 100000 },
    "tmp": { "...": "same shape" }, "cache": { "...": "same shape" }, "output": { "...": "same shape" },
    "mounts": [ { "hostPath": "...", "path": "...", "writable": false } ] },
  "policies": { "resources": { "cpus": 2, "memoryMiB": 3072, "tasksMax": 512, "timeoutMinutes": 90 },
    "network": { "egress": "allowlist", "allow": [ "crates.io", "github.com", "static.crates.io" ] },
    "capabilities": [ "github-comment", "github-read" ] },
  "digests": { "template": "<sha256>", "lockedSources": "<sha256>" }
}
```

- `locked` is `null` exactly when `resolve = "assignment"`, and otherwise always carries
  `rev`, `narHash` and `storePath`. The run manifest (#136, #138) records that run's single
  resolved revision and references `digests.template`.
- `digests.template` is sha256 over the canonical JSON of every field above `digests` (Nix
  sorts keys): any template field, package store path or locked revision moves it.
  `digests.lockedSources` covers each source's name with its locked `rev` and `narHash`
  (`null` for an assignment-resolved source) and the skills source's `rev` and `narHash`, so a
  nixpkgs bump moves `digests.template` but not `digests.lockedSources`. The per-run
  resolution digest belongs to the run manifest.
- Store paths keep their Nix string context, so `nix build .#agent-runtime-manifests` realizes
  the whole template closure and the `result` link is a GC root for it. Only `name` and
  `storePath` of a package are serialized.
- `policies.network.egress` is `"none"` with `allow: []` when `network.allow = null`, else
  `"allowlist"`; `allow` and `capabilities` are emitted sorted and deduplicated.
- Credentials never belong here. `capabilities` and `writable` declare intent; grants are per
  run and outside the store (#137). `agent-runtime-eval` refuses an example manifest with a
  secret-like field name or a value that looks like a GitHub, Anthropic or AWS key or a
  private key.

## Checks

- `nix flake check`: `checks.x86_64-linux.agent-runtime-eval`.
- `devenv tasks run nixos:agent-runtime-test` (part of `nixos:qa`): `scripts/test-agent-runtime.sh`
  evaluates `tests/agent-runtime` as an external consumer flake with this repo as its
  `nixos-config` input (`--override-input`; no module code is vendored into it): the two
  templates, the consumer
  `nixosSystem`'s toplevel (eval only), the same host with a bad template refused through
  NixOS's own assertions, and every negative case with its message.

## Runtime adapter: assign, materialize, export, reclaim (#136)

Four executables (`nix build .#agent-runtime-{assign,materialize,export,reclaim}`, also
`lib.agentRuntime.tools`) turn a template manifest into pinned source trees at the declared
paths. Every failure ends stderr with one JSON line, `{"error":{"class","message"}}`, and the
class is the exit code: `usage` 2, `github` 3 (resolution), `nix` 4 (prefetch) or `store` 4
(a missing or mismatching store path), `credential` 5, `path`/`source` 6, `state` 1.

```sh
agent-runtime-assign --template rust-worker.json --run r1 --out runs/r1 --plan plan.json
agent-runtime-materialize --run runs/r1/run.json --root instances/r1
agent-runtime-export --root instances/r1 --out exports/r1
agent-runtime-reclaim --root instances/r1
```

- **assign** freezes the sources once, on the assigning host, before anything executes. A
  `resolve = "lock"` source copies its lock. A `resolve = "assignment"` source takes its commit
  from a devenv-platform `prepare:plan` document (`schema_version: 1`, matched by
  `source.repo` and `source.ref`; [devenv-platform#92](https://github.com/sammasak/devenv-platform/issues/92)
  owns that resolver, nothing is copied) and prefetches it with `nix flake prefetch`. A
  private source needs `GH_TOKEN`, which reaches `nix` as an access token through its
  environment and nothing else; error text is redacted. The result, `run.json`
  (`agent-runtime-run`, schemaVersion 1), records per source the repository, requested ref,
  resolved `rev`, `narHash`, `storePath` and whether the lock or the plan resolved it, plus
  `digests.run` over the sources. A run is assigned once; a branch that advances between two
  assignments changes only the later run.
- **materialize** needs no network and nothing it was not given: the run manifest and a
  root. It verifies each store path's NAR hash against the run manifest, refuses a path
  outside the workspace, a non-normalized path, a symlink that resolves outside its tree and
  a missing store path (reported as `store`, apart from any GitHub failure), and on failure
  leaves nothing under the root. A read-only source binds its store path; a writable one is
  copied into `ROOT/workspace/<name>` (owner-writable, bytes recorded), so two instances of
  one source never share a byte. `ROOT/binds` lists `mode source path` lines for #137 to bind,
  `ROOT/materialized.json` is the instance record, and `ROOT/export-pending` names the writable
  checkouts whose state has not been exported.
- **export** writes, per writable checkout, `<name>.patch` (`diff -ruN --no-dereference` against the
  pinned store path: new files included, a symlink compared as a link) and `<name>.json` (base `rev`/`narHash`/`storePath`, changed
  paths, patch digest and size), plus `export.json`; it clears the marker and deletes nothing.
  Binary changes are listed, not reapplied; the evidence bundle around this is
  [devenv-platform#95](https://github.com/sammasak/devenv-platform/issues/95).
- **reclaim** removes `ROOT/workspace` and refuses while `export-pending` exists: no source
  state disappears before export.

The checkouts are trees, not git repositories (`fetchTree` strips `.git`); a run that needs
history or push rights is a capability question for #137, not a materialization one.
`checks.x86_64-linux.agent-runtime-runtime` drives all four against fixture trees with a fake
`nix` that answers `flake prefetch` from a table.

## Limits of this milestone

- `systemd-nspawn` shares the host kernel; a template declares a boundary, it does not enforce
  one. Mount budgets (bytes and inodes), `host.reserve`, `resources`, `network` and
  `capabilities` are inputs for #137 (admission and enforcement); `maxConcurrentInstances`
  and `timeoutMinutes` for #138 (lifecycle). `host.enable` only gates `eligibleTemplates` at
  evaluation; nothing acts on it yet.
- A writable host mount is shared by every instance that binds it, across templates and
  concurrent runs; #137/#138 must give each instance its own subdirectory or refuse the
  overlap.
- A read-only `/nix/store` is not a confidential one: an instance that sees the whole store
  reads every path on the host, not just its pinned closure, unless #135/#137 mount only the
  closure.
- The eval-time `hostPath` check is a prefix check on declared strings; #137 must resolve the
  host path at admission (realpath) and re-check the resolved path against the allowed roots,
  or refuse any symlink component, before binding.
- `allow` names are checked for shape only. #137 must enforce the allowlist at resolution
  time with a pinned resolver and refuse answers in private, link-local or loopback ranges;
  a name under a wildcard DNS or `.internal` zone can still point anywhere.
- `lock` is trusted: nothing ties a locked input to `github` or proves `ref.value` is on that
  revision. The manifest records what the declaration said. Likewise a plan is trusted to
  name the right commit; the prefetch pins its content.
- `materialize` bounds nothing by itself: the workspace copy's size is recorded, enforcing
  the budgets (bytes and inodes) is #137's. The `binds` file is a request, not a mount.
- `role.name` is a free name until [sammasak/skills#63](https://github.com/sammasak/skills/issues/63)
  binds it to `agents/<role>/ROLE.md`.
