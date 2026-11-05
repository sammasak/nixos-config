# Agent runtime templates (M0: typed module, manifests)

Epic: [nixos-config#133](https://github.com/sammasak/nixos-config/issues/133). This milestone
delivers the declarative half only: a reusable NixOS module that types what an ephemeral
`systemd-nspawn` agent instance would contain, and a versioned manifest per template. Nothing
in this module starts a container, adds a service, or touches a live host; the nspawn proof
(#135), source materialization (#136), security and admission (#137) and lifecycle (#138)
consume the manifest.

Terms: a **template** is a declaration under `sam.agentRuntime.templates.<name>`. An
**instance** is one ephemeral container made from it; one instance serves one **run**, the
execution of one **assignment** (the task handed to the run). A source with
`resolve = "assignment"` is resolved to a revision at that moment (#136), not from
`flake.lock`. The **template manifest** (this milestone) describes the template; the **run
manifest** (#136, #138) records what one run resolved and did.

## Using it from another flake

```nix
inputs = {
  nixos-config.url = "github:sammasak/nixos-config";
  factum = { url = "github:sammasak/factum"; flake = false; };   # a source repo
  skills = { url = "github:sammasak/skills"; flake = false; };   # the skills tree
};
```

In a host, import the module and declare `sam.agentRuntime` as below. Without a host, the
standalone evaluator returns `sam.agentRuntime` with `manifestData` and `manifestDir` filled
in, or throws the failed checks:

```nix
imports = [ inputs.nixos-config.nixosModules.agent-runtime ];                  # in a host

manifests = (inputs.nixos-config.lib.agentRuntime { inherit pkgs; }).evalManifests {
  modules = [ ./templates.nix ];                                               # without one
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

The generated reference (`nix build .#agent-runtime-options`) is authoritative. The shape:

- `sam.agentRuntime.templates.<name>`: a description of possible instances.
  - `role = { name; harness = "claude-code" | "codex" | "pi"; }` (`name` is a lowercase DNS
    label)
  - `repositories.<name> = { github = "owner/repo"; ref = { type = "branch" | "tag" | "commit";
    value; }; resolve ? "lock"; lock ? null; path; writable ? false; }` with
    `lock = inputs.<input>`
  - `skillsSource = inputs.skills;` and `skills.<skill-dir-name> = { }`
  - `packages = with pkgs; [ ... ]`
  - `filesystem`: `workspace ? "/workspace"` (parent of every repository path); the private
    mounts `home` (`/home/agent`), `tmp` (`/tmp`), `cache` (`/var/cache/agent`), `output`
    (`/output`), each `{ path ? <that default>; sizeMiB; inodes ? 100000; }`; and
    `mounts = [ { hostPath; path; writable ? false; } ]`, host bind mounts restricted by
    `host.allowedMountRoots`
  - `resources = { cpus; memoryMiB; tasksMax ? 512; timeoutMinutes; }`
  - `network = { egress ? "none"; allow ? [ ]; }` with `egress = "none" | "allowlist"` and
    `allow` a list of DNS names
  - `capabilities ? [ ]`: a subset of `github-read`, `github-comment`, `github-push`. A
    writable checkout never implies `github-push`.
- `sam.agentRuntime.host`, host policy separate from templates: `enable ? false` (must be
  true before any template is eligible; it starts nothing), `eligibleTemplates ? [ ]`,
  `maxConcurrentInstances ? 1`, `reserve.{memoryMiB ? 2048, diskMiB ? 10240}`,
  `allowedMountRoots ? [ ]` (so no host mount is allowed by default; a string is a read-only
  root, `{ path; writable = true; }` lets templates bind it read-write; the most specific
  covering root decides).
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
```

The ref rule, by `ref.type` and `resolve`:

| `ref.type` | `resolve = "lock"` (default) | `resolve = "assignment"` |
|---|---|---|
| `branch`, `tag` | `lock` required; `lock.rev` is the identity, `ref.value` the label it was taken at (not verified against the input) | `lock` forbidden; the run resolves the ref once (#136) |
| `commit` | `lock` required and `lock.rev` must equal the commit (the lock carries the content identity) | refused (a commit needs no resolution) |

No evaluation fetches anything: every revision comes from a locked input or is left to the run.

## Validation

Each case below fails evaluation (no manifest is produced) with a message that names the
option. The canonical list is `tests/agent-runtime/cases.nix` (every case maps to a row; some
rows cover two cases):

| Case | Message contains |
|---|---|
| `ref.type = "sha"` | `ref.type' is not of type` |
| commit value not 40-hex | `a commit ref must be a 40-hex revision` |
| branch/tag/commit without `lock` | `` needs `lock = inputs.<input>` `` |
| `lock.rev` differs from the commit | `differs from the commit` |
| `resolve = "assignment"` with `lock` | `` drop `lock` `` |
| commit with `resolve = "assignment"` | `a commit needs no resolution` |
| branch name like `--upload-pack=x` (leading `-` or `.`, `..`, `//`, a component ending in `.` or `.lock`) | `` ref.value' is not of type `git ref name `` |
| two paths equal or nested (repos, private mounts, host mounts; the workspace when there are no repos) | `instance paths overlap` |
| a path on `/nix`, `/etc`, `/proc`, `/sys`, `/dev`, `/run`, `/usr`, `/bin`, `/lib`, `/lib64`, `/sbin`, `/boot`, `/root`, `/var/lib` | `instance path on a reserved root` |
| same `github` + ref twice | `duplicate repository identity` |
| repo path outside `filesystem.workspace` | `is not under filesystem.workspace` |
| `.`/`..`, `//`, relative, trailing slash, or characters outside `[A-Za-z0-9._-]` | `` path' is not of type `absolute normalized path `` |
| repository without `path` | `path' was accessed but has no value defined` |
| `lock.outPath` a path literal (would copy into the store) | `lock.outPath' is not of type` |
| skill without `<skillsSource>/skills/<name>/SKILL.md`, or a name with `/` | `not in skills source` (lists the known names) |
| `memoryMiB = "4G"` | `memoryMiB' is not of type` |
| mount `hostPath` outside `host.allowedMountRoots` | `unauthorized host mount` |
| `writable = true` under a read-only root (the most specific covering root decides) | `read-write but its allowed mount root <root> is read-only` |
| `egress = "allowlist"` with empty `allow` | `` needs a non-empty `allow` `` |
| `allow` with `egress = "none"` | `` `allow` needs egress = "allowlist" `` |
| an IP literal or single-label name in `allow` | `` is not of type `DNS name `` |
| `host.eligibleTemplates` names no template | `names unknown template` |
| `host.eligibleTemplates` with `host.enable = false` | `host.enable is false` |
| an allowed mount root on `/nix`, `/etc`, `/proc`, `/sys`, `/dev`, `/run`, `/boot`, `/root`, `/home` | `is on a denied host root` |

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
  nixpkgs bump moves `digests.template` but not `digests.lockedSources`. The per-run resolution digest belongs to
  the run manifest.
- Store paths keep their Nix string context, so `nix build .#agent-runtime-manifests` realizes
  the whole template closure and the `result` link is a GC root for it. Only `name` and
  `storePath` of a package are serialized.
- `allow` and `capabilities` are emitted sorted and deduplicated.
- Credentials never belong here. `capabilities` and `writable` declare intent; grants are per
  run and outside the store (#137). `agent-runtime-eval` refuses an example manifest with a
  secret-like field name or a value that looks like a GitHub, Anthropic or AWS key or a
  private key.

## Checks

- `nix flake check`: `checks.x86_64-linux.agent-runtime-eval`.
- `devenv tasks run nixos:agent-runtime-test` (part of `nixos:qa`): `scripts/test-agent-runtime.sh`
  evaluates `tests/agent-runtime` as an external consumer flake with this repo as its
  `nixos-config` input (`--override-input`, nothing copied): the two templates, the consumer
  `nixosSystem`'s toplevel (eval only), the same host with a bad template refused through
  NixOS's own assertions, and every negative case with its message.

## Limits of this milestone

- `systemd-nspawn` shares the host kernel; a template declares a boundary, it does not enforce
  one. Mount budgets (bytes and inodes), `host.reserve`, `resources`, `network` and
  `capabilities` are inputs for #137 (admission and enforcement); `maxConcurrentInstances`
  and `timeoutMinutes` for #138 (lifecycle). `host.enable` is recorded only.
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
  revision. The manifest records what the declaration said.
- `role.name` is a free name until [sammasak/skills#63](https://github.com/sammasak/skills/issues/63)
  binds it to `agents/<role>/ROLE.md`. Options exist only where an issue in this epic names a
  consumer.
