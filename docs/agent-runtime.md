# Agent runtime templates (M0: typed module, manifests)

Epic: [nixos-config#133](https://github.com/sammasak/nixos-config/issues/133). This milestone
delivers the declarative half only: a reusable NixOS module that types what an ephemeral
`systemd-nspawn` agent instance would contain, and a versioned manifest per template. Nothing
in this module starts a container, adds a service, or touches a live host; the nspawn proof
(#135), source materialization (#136), security/admission (#137) and lifecycle (#138) consume
the manifest.

## Public API

| Output | What |
|---|---|
| `nixosModules.agent-runtime` (also `modules.nixos.agent-runtime`) | the NixOS module; options under `sam.agentRuntime` |
| `lib.agentRuntime { pkgs }` → `evalManifests { modules }` | evaluate templates without a `nixosSystem`; returns `sam.agentRuntime` (manifests included) or throws the failed assertions |
| `packages.x86_64-linux.agent-runtime-options` | option reference (CommonMark) generated from the module |
| `packages.x86_64-linux.agent-runtime-manifests` | the example templates' manifests, one `<name>.json` per template |
| `checks.x86_64-linux.agent-runtime-eval` | the example templates build their manifests (shape checked with jq); every negative case fails evaluation |

Options (full reference: `nix build .#agent-runtime-options`):

- `sam.agentRuntime.templates.<name>` — one template, a description of **possible** instances.
  - `role = { name; harness = "claude-code" | "codex" | "pi"; }`
  - `repositories.<name> = { github = "owner/repo"; ref = { type = "branch" | "tag" | "commit"; value; }; resolve = "lock" | "assignment"; lock = inputs.<name>; path; writable; }`
  - `skillsSource = inputs.skills;` and `skills.<skill-dir-name> = { }` (each may override `source`)
  - `packages = with pkgs; [ ... ]`
  - `filesystem = { workspace; home; tmp; cache; output; mounts; }` with a byte and inode budget per private mount
  - `resources = { cpus; memoryMiB; tasksMax; timeoutMinutes; }`, `network = { egress = "none" | "allowlist"; allow; }`, `capabilities`
- `sam.agentRuntime.host` — host policy, separate from templates: `enable`, `eligibleTemplates`,
  `maxConcurrentInstances`, `reserve.{memoryMiB,diskMiB}`, `allowedMountRoots`.
- Read-only results: `manifestData.<name>` (attrset), `manifests.<name>` (JSON file),
  `manifestDir`.

## Example: a Rust worker

From `tests/agent-runtime/templates.nix` (the fixture the checks evaluate). `factum` and
`skills` are this flake's inputs with `flake = false`, so their `rev`/`narHash`/`outPath` come
from `flake.lock`:

```nix
sam.agentRuntime.templates.rust-worker = {
  role = { name = "rust-worker"; harness = "claude-code"; };
  repositories.factum = {
    github = "sammasak/factum";
    ref = { type = "branch"; value = "main"; };   # locked: lock.rev is the revision used
    lock = inputs.factum;
    path = "/workspace/factum";
    writable = true;                              # a private copy; never push rights
  };
  skillsSource = inputs.skills;
  skills = { rust-engineering = { }; nix-flake-development = { }; };
  packages = with pkgs; [ cargo rustc gcc git ];
  filesystem = {
    home.sizeMiB = 512; tmp.sizeMiB = 1024; cache.sizeMiB = 4096; output.sizeMiB = 256;
    mounts = [ { hostPath = "/srv/agent-runtime/cache/cargo-registry"; path = "/var/cache/cargo-registry"; } ];
  };
  resources = { cpus = 2; memoryMiB = 3072; timeoutMinutes = 90; };
  network = { egress = "allowlist"; allow = [ "github.com" "crates.io" "static.crates.io" ]; };
  capabilities = [ "github-read" "github-comment" ];
};
```

The three ref forms:

```nix
ref = { type = "commit"; value = "5bb7fa304db7d8ae7d422e8d6356bf06b90d3b41"; };          # the identity itself
ref = { type = "branch"; value = "main"; }; lock = inputs.factum;                         # resolved by flake.lock
ref = { type = "tag"; value = "v0.2.0"; }; resolve = "assignment";                        # resolved once per run (#136)
```

A branch or tag with the default `resolve = "lock"` needs `lock`; `resolve = "assignment"`
forbids it (one source of truth). A commit never resolves. No evaluation fetches anything:
every revision comes from a locked input or is left for the run.

## Validation (fails evaluation, and the manifest is unreachable)

Each message names the option. Covered by `tests/agent-runtime/cases.nix`:

| Case | Message contains |
|---|---|
| `ref.type = "sha"` | `one of "branch", "tag", "commit"` |
| commit value not 40-hex | `a commit ref must be a 40-hex revision` |
| branch/tag without `lock` | `` needs `lock = inputs.<name>` `` |
| `lock.rev` ≠ commit | `differs from the commit` |
| `resolve = "assignment"` with `lock` | `` drop `lock` `` |
| two paths equal or nested (repos, home/tmp/cache/output, mounts) | `instance paths overlap` |
| same `github` + ref twice | `duplicate repository identity` |
| repo path outside `filesystem.workspace` | `is not under filesystem.workspace` |
| `..`, `//`, relative or trailing-slash path | `absolute normalized path` |
| skill not a directory of `<skillsSource>/skills` | `not in skills source` (lists the known names) |
| `memoryMiB = "4G"` | `is not of type` |
| mount `hostPath` outside `host.allowedMountRoots` | `unauthorized host mount` |
| `egress = "allowlist"` with empty `allow` | `` needs a non-empty `allow` `` |
| `host.eligibleTemplates` names no template | `names unknown template` |

## Manifest (`agent-runtime-template`, schemaVersion 1)

Generated from the evaluated declaration; JSON is output, never input.

```json
{
  "schemaVersion": 1, "kind": "agent-runtime-template",
  "template": { "name": "rust-worker" },
  "role": { "name": "rust-worker", "harness": "claude-code" },
  "sources": { "factum": { "github": "sammasak/factum", "ref": { "type": "branch", "value": "main" },
    "resolve": "lock", "locked": { "rev": "<40 hex>", "narHash": "sha256-…", "storePath": "/nix/store/…-source" },
    "path": "/workspace/factum", "writable": true } },
  "skills": { "rust-engineering": { "source": { "rev": "<40 hex>", "narHash": "…", "storePath": "…" }, "path": "/nix/store/…-source/skills/rust-engineering" } },
  "packages": [ { "name": "cargo", "storePath": "/nix/store/…-cargo-…" } ],
  "filesystem": { "workspace": "/workspace", "home": { "path": "/home/agent", "sizeMiB": 512, "inodes": 100000 }, "tmp": {}, "cache": {}, "output": {}, "mounts": [] },
  "policies": { "resources": {}, "network": {}, "capabilities": [] },
  "digests": { "template": "<sha256>", "lockedSources": "<sha256>" }
}
```

- `locked` is `null` exactly when `resolve = "assignment"`; the run manifest (#136/#138) records
  that run's single resolved revision and references `digests.template`.
- `digests.template` is sha256 over the canonical JSON of everything above `digests` (Nix
  sorts keys): it changes with any declaration, package, skills or source revision.
  `digests.lockedSources` covers only the locked revisions (`sources.*.locked.rev`,
  `skills.*.source.rev`), so a nixpkgs bump moves the first and not the second.
- Store paths are strings with references: `nix build .#agent-runtime-manifests` realizes the
  template closure and the result link is a GC root for it. No live package objects are
  serialized, only `name` and `storePath`.
- Credentials never belong here. `capabilities` and `writable` declare intent; grants are
  per run and outside the store (#137).

## Checks

- `nix flake check` → `checks.x86_64-linux.agent-runtime-eval`.
- `devenv tasks run nixos:agent-runtime-test` (part of `nixos:qa`): `scripts/test-agent-runtime.sh`
  evaluates `tests/agent-runtime` as an **external consumer flake** with this repo as its
  `nixos-config` input (`--override-input`, nothing copied): two templates, a `nixosSystem`
  importing the module, and every negative case with its message.

## Limits of this milestone

`systemd-nspawn` shares the host kernel; a template declares a boundary, it does not enforce
one. `resources`, `network`, `capabilities` and the mount budgets are policy inputs for #137;
`host.reserve` and `maxConcurrentInstances` are admission inputs for #138. The `role.name` is a
free name until skills#63 binds it to `agents/<role>/ROLE.md`. Options exist only where an
M0/M1 consumer is named.
