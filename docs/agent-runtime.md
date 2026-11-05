# Agent runtime templates (M0: typed module, manifests)

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
resolved to a revision at that moment (#136), not from `flake.lock`. The **template manifest**
(this milestone) describes the template; the **run manifest** (#136, #138) records what one
run resolved and did. Options exist only where an issue in this epic names a consumer.

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

The generated reference (`nix build .#agent-runtime-options`) is authoritative. The shape,
where `x ? d` defaults to `d` and every other field is required (notably `skillsSource`, each
private mount's `sizeMiB`, and `cpus`, `memoryMiB`, `timeoutMinutes`):

- `sam.agentRuntime.templates.<name>`: a description of possible instances; the name, like
  every repository name and `role.name`, is lowercase letters, digits and `-`.
  - `role = { name; harness = "claude-code" | "codex" | "pi"; }`
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
with a message that names the option; the checks run all of them and match the messages. What
is refused:

- refs: a `ref.type` outside `branch | tag | commit`; a branch, tag or commit without `lock`
  (or with one under `resolve = "assignment"`, or a commit under `assignment` at all); a commit
  whose `lock.rev` differs from it; a ref name git would reject (a leading `-` or `.`, `..`,
  `//`, a component ending in `.` or `.lock`).
- sources: the same `github` + ref twice; a repository without `path`; a path outside or equal
  to `filesystem.workspace`; a `lock.outPath` that is a path literal (it would copy into the
  store); a template or repository name that is not lowercase letters, digits and `-`.
- paths: any two of repository paths, private mounts, host-mount targets and the workspace
  equal or nested (a repository under the workspace is the one allowed pair); a path on, or
  containing, `/nix`, `/etc`, `/proc`, `/sys`, `/dev`, `/run`, `/usr`, `/bin`, `/lib`,
  `/lib64`, `/sbin`, `/boot`, `/root`, `/var/lib`; a path with `.`/`..`, `//`, a trailing
  slash, or characters outside `[A-Za-z0-9._-]`.
- skills: a name without `<skillsSource>/skills/<name>/SKILL.md` (the message lists the known
  names), including any name with `/`.
- policy: a value of the wrong type (`memoryMiB = "4G"`, an IP literal or single-label name in
  `allow`, an empty `allow` list, an unknown harness or capability).
- host: a mount whose `hostPath` is under no allowed root, or bound read-write under a
  read-only root (the most specific covering root decides); an allowed root declared twice;
  an allowed root on, or containing, `/nix`, `/etc`, `/proc`, `/sys`, `/dev`, `/run`,
  `/var/run`, `/var/lib`, `/usr`, `/tmp`, `/boot`, `/root`, `/home`; `eligibleTemplates`
  naming no template, or set while `host.enable` is false.

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
  revision. The manifest records what the declaration said.
- `role.name` is a free name until [sammasak/skills#63](https://github.com/sammasak/skills/issues/63)
  binds it to `agents/<role>/ROLE.md`.
