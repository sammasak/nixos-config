# Agent runtime templates (M0: typed module, manifests)

Epic: [nixos-config#133](https://github.com/sammasak/nixos-config/issues/133). This milestone
delivers the declarative half only: a reusable NixOS module that types what an ephemeral
`systemd-nspawn` agent instance would contain, and a versioned manifest per template. Nothing
in this module starts a container, adds a service, or touches a live host; the nspawn proof
(#135), source materialization (#136), security and admission (#137) and lifecycle (#138)
consume the manifest.

Terms: a **template** is a declaration under `sam.agentRuntime.templates.<name>`. An
**instance** is one ephemeral container made from it; one instance serves one **run**, the
execution of one assigned task. The **template manifest** (this milestone) describes the
template; the **run manifest** (#136, #138) records what one run resolved and did.

## Using it from another flake

```nix
inputs = {
  nixos-config.url = "github:sammasak/nixos-config";
  factum = { url = "github:sammasak/factum"; flake = false; };   # a source repo
  skills = { url = "github:sammasak/skills"; flake = false; };   # the skills tree
};
```

In a host: `imports = [ inputs.nixos-config.nixosModules.agent-runtime ];` and declare
`sam.agentRuntime` as below. Without a host: `(inputs.nixos-config.lib.agentRuntime { inherit pkgs; })
.evalManifests { modules = [ ./templates.nix ]; }` returns `sam.agentRuntime` with
`manifestData` and `manifestDir` filled in, or throws the failed checks. The reference consumer
is `tests/agent-runtime/flake.nix`.

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
  - `role = { name; harness = "claude-code" | "codex" | "pi"; }`
  - `repositories.<name> = { github = "owner/repo"; ref = { type = "branch" | "tag" | "commit";
    value; }; resolve = "lock" | "assignment"; lock = inputs.<name>; path; writable; }`
  - `skillsSource = inputs.skills;` and `skills.<skill-dir-name> = { }` (each may override
    `source`)
  - `packages = with pkgs; [ ... ]`
  - `filesystem`: `workspace` (parent of every repository path); the private mounts `home`,
    `tmp`, `cache`, `output`, each `{ path ? <default>; sizeMiB; inodes ? 100000; }`; and
    `mounts = [ { hostPath; path; readOnly ? true; } ]`, host bind mounts restricted by
    `host.allowedMountRoots`
  - `resources = { cpus; memoryMiB; tasksMax ? 512; timeoutMinutes; }`
  - `network = { egress = "none" | "allowlist"; allow = [ <DNS names> ]; }`, default no egress
  - `capabilities`: a subset of `github-read`, `github-comment`, `github-push`; default none.
    A writable checkout never implies `github-push`.
- `sam.agentRuntime.host`, host policy separate from templates: `enable` (must be true before
  any template is eligible; it starts nothing), `eligibleTemplates`, `maxConcurrentInstances`,
  `reserve.{memoryMiB,diskMiB}`, `allowedMountRoots` (a string is a read-only root; `{ path;
  writable = true; }` lets templates bind it read-write).
- Results: `manifestData.<name>` (attrset) and `manifestDir` (`<name>.json` files).

## Example: a Rust worker

From `tests/agent-runtime/templates.nix`, the fixture the checks evaluate. `factum` and
`skills` are flake inputs with `flake = false`, so their `rev`, `narHash` and `outPath` come
from `flake.lock`:

```nix
sam.agentRuntime.templates.rust-worker = {
  role = { name = "rust-worker"; harness = "claude-code"; };
  repositories = {
    factum = {                                    # a branch, locked by the flake input
      github = "sammasak/factum";
      ref = { type = "branch"; value = "main"; };
      lock = inputs.factum;
      path = "/workspace/factum";
      writable = true;                            # a private copy; never push rights
    };
    factum-pinned = {                             # an exact commit (lock optional, rev must match)
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
  packages = with pkgs; [ cargo rustc gcc git ];
  filesystem = {
    home.sizeMiB = 512; tmp.sizeMiB = 1024; cache.sizeMiB = 4096; output.sizeMiB = 256;
    mounts = [
      { hostPath = "/srv/agent-runtime/cache/cargo-registry"; path = "/var/cache/cargo-registry"; }
    ];
  };
  resources = { cpus = 2; memoryMiB = 3072; timeoutMinutes = 90; };
  network = { egress = "allowlist"; allow = [ "github.com" "crates.io" "static.crates.io" ]; };
  capabilities = [ "github-read" "github-comment" ];
};
```

The ref rule, by `ref.type` and `resolve`:

| `ref.type` | `resolve = "lock"` (default) | `resolve = "assignment"` |
|---|---|---|
| `branch`, `tag` | `lock` required; `lock.rev` is the identity, `ref.value` the label it was taken at (not verified against the input) | `lock` forbidden; the run resolves the ref once (#136) |
| `commit` | `lock` optional; if given, `lock.rev` must equal the commit | refused (a commit needs no resolution) |

No evaluation fetches anything: every revision comes from a locked input or is left to the run.

## Validation

Every case fails evaluation, so no manifest exists; each message names the option. The
canonical list is `tests/agent-runtime/cases.nix` (one case per row; the checks run all of
them):

| Case | Message contains |
|---|---|
| `ref.type = "sha"` | `ref.type' is not of type` |
| commit value not 40-hex | `a commit ref must be a 40-hex revision` |
| branch/tag without `lock` | `` needs `lock = inputs.<name>` `` |
| `lock.rev` differs from the commit | `differs from the commit` |
| `resolve = "assignment"` with `lock` | `` drop `lock` `` |
| commit with `resolve = "assignment"` | `a commit needs no resolution` |
| branch name like `--upload-pack=x` (no leading `-`, `..`, `//`, `@{`, trailing `/`, `.lock`) | `` ref.value' is not of type `git ref name `` |
| two paths equal or nested (repos, private mounts, host mounts, workspace) | `instance paths overlap` |
| a path on `/nix`, `/etc`, `/proc`, `/sys`, `/dev`, `/run`, `/usr`, `/bin` | `instance path on a reserved root` |
| same `github` + ref twice | `duplicate repository identity` |
| repo path outside `filesystem.workspace` | `is not under filesystem.workspace` |
| `.`/`..`, `//`, relative, trailing slash, or characters outside `[A-Za-z0-9._-]` | `absolute normalized path` |
| repository without `path` | `path' was accessed but has no value defined` |
| `lock.outPath` a path literal (would copy into the store) | `outPath' is not of type` |
| skill without `<source>/skills/<name>/SKILL.md`, or a name with `/` | `not in skills source` (lists the known names) |
| `memoryMiB = "4G"` | `memoryMiB' is not of type` |
| mount `hostPath` outside `host.allowedMountRoots` | `unauthorized host mount` |
| `readOnly = false` under a read-only root | `read-write but its allowed mount root is read-only` |
| `egress` and `allow` disagree | `` needs a non-empty `allow` `` / `` `allow` needs egress `` |
| an IP literal or single-label name in `allow` | `network.allow` type error |
| `host.eligibleTemplates` names no template | `names unknown template` |
| `host.eligibleTemplates` with `host.enable = false` | `host.enable is false` |

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
    "rust-engineering": { "source": { "rev": "<40 hex>", "narHash": "sha256-...", "storePath": "..." },
      "path": "/nix/store/...-source/skills/rust-engineering" }
  },
  "packages": [ { "name": "cargo", "storePath": "/nix/store/...-cargo-..." } ],
  "filesystem": { "workspace": "/workspace",
    "home": { "path": "/home/agent", "sizeMiB": 512, "inodes": 100000 },
    "tmp": { "...": "same shape" }, "cache": { "...": "same shape" }, "output": { "...": "same shape" },
    "mounts": [ { "hostPath": "...", "path": "...", "readOnly": true } ] },
  "policies": { "resources": { "cpus": 2, "memoryMiB": 3072, "tasksMax": 512, "timeoutMinutes": 90 },
    "network": { "egress": "allowlist", "allow": [ "crates.io", "github.com", "static.crates.io" ] },
    "capabilities": [ "github-comment", "github-read" ] },
  "digests": { "template": "<sha256>", "lockedSources": "<sha256>" }
}
```

- `locked` is `null` exactly when `resolve = "assignment"`; a commit without `lock` records
  `{ rev, narHash: null, storePath: null }`. The run manifest (#136, #138) records that run's
  single resolved revision and references `digests.template`.
- `digests.template` is sha256 over the canonical JSON of every field above `digests` (Nix
  sorts keys): any template field, package store path or locked revision moves it.
  `digests.lockedSources` covers each source's and skill's name with its locked `rev` and
  `narHash` (`null` for an assignment-resolved source), so a nixpkgs bump moves
  `digests.template` but not `digests.lockedSources`. The per-run resolution digest belongs to
  the run manifest.
- Store paths keep their Nix string context, so `nix build .#agent-runtime-manifests` realizes
  the whole template closure and the `result` link is a GC root for it. Only `name` and
  `storePath` of a package are serialized.
- `allow` and `capabilities` are emitted sorted and deduplicated.
- Credentials never belong here. `capabilities` and `writable` declare intent; grants are per
  run and outside the store (#137). The check refuses a manifest with a secret-like field name
  or a value that looks like a GitHub token or private key.

## Checks

- `nix flake check`: `checks.x86_64-linux.agent-runtime-eval`.
- `devenv tasks run nixos:agent-runtime-test` (part of `nixos:qa`): `scripts/test-agent-runtime.sh`
  evaluates `tests/agent-runtime` as an external consumer flake with this repo as its
  `nixos-config` input (`--override-input`, nothing copied): two templates, the consumer
  `nixosSystem`'s toplevel (eval only), and every negative case with its message.

## Limits of this milestone

- `systemd-nspawn` shares the host kernel; a template declares a boundary, it does not enforce
  one. Mount budgets (bytes and inodes), `host.reserve`, `resources`, `network` and
  `capabilities` are inputs for #137 (admission and enforcement); `maxConcurrentInstances`
  and `timeoutMinutes` for #138 (lifecycle). `host.enable` is recorded only.
- A read-only `/nix/store` is not a confidential one: an instance that sees the whole store
  reads every path on the host, not just its pinned closure, unless #135/#137 mount only the
  closure.
- The eval-time `hostPath` check is a prefix check on declared strings; #137 must canonicalize
  the host path (realpath, no symlink following) at admission before binding.
- `lock` is trusted: nothing ties a locked input to `github` or proves `ref.value` is on that
  revision. The manifest records what the declaration said.
- `role.name` is a free name until skills#63 (`sammasak/skills#63`) binds it to
  `agents/<role>/ROLE.md`. Options exist only where an issue in this epic names a consumer.
