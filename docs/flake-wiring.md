# Flake wiring: one hosts table, the role registry stays

Status: proposed, 2026-11-13; the owner has not decided yet. This records a
decision, not the current code: until steps 1 to 5 below land,
`flake-modules/hosts/*.nix`, `70-deploy.nix` and the registry work as
described in `docs/architecture.md`. Tracking issue: #292 (roadmap #295,
wave 3).

| Step | Change | State |
|---|---|---|
| P | `just parity` derives its host list and compares deploy nodes and settings | landed with this file |
| 0 | this document | landed |
| 1 | `sam.profile.username` becomes an enum of `lib/users.nix` | landed |
| 2 | architecture stated once (`hostPlatform`) | landed |
| 3 | one table value file `flake-modules/hosts.nix`, roles in it | not started |
| 4 | deploy nodes derived from the table | not started |
| 5 | registry comment: its depth fixes merge order | not started |

Evidence: flake.nix, flake-modules/, hosts/*/, lib/users.nix and the roles at
main 72d7bd5; nixpkgs fe13242 (eval-config.nix, misc/nixpkgs.nix,
lib/modules.nix); flake-parts 024633c (extras/modules.nix). Prototypes were
evaluated, not built, from `git archive` copies, one host at a time.

## Context

Flake wiring for a host lives in two files, `flake-modules/hosts/<name>.nix`
and its node in `70-deploy.nix`. Before step 2, architecture was stated three
times: `system` there, `nixpkgs.hostPlatform` in `hardware-configuration.nix`, and the
`x86`/`aarch64` activate per node. Nothing checked that they agreed.

The issue's other claims, checked against the code:

- **"A username typo yields a host with no SSH keys."** Not quite. With
  naked-pi's username set to `lukass`, the toplevel already fails to
  evaluate, with the misleading `deploy-target: lenovo's key is missing`.
  Reading an option directly (`config.users.users.lukass.openssh.authorizedKeys.keys`)
  silently gives `[ ]`, because of `users.${username} or { }`.
- **"import-tree is used for one call; docs claim an ordering."** #306
  already fixed the docs. One small input loading one directory is a style
  point.
- **"The registry only turns a name into a path."** True as code, but **its
  nesting decides merge order**. The module system collects imports
  breadth-first (`genericClosure`), so import depth decides where definitions
  land in list and lines merges, and flake-parts nests each `flake.modules`
  entry three levels deep. Plain paths moved all five toplevels. Attributed
  on lenovo, each lookup on its own:
  - the Home Manager lookup (`config.flake.modules.homeManager.default`)
    reorders `home-manager-path`, fish completions, man paths, fontconfig,
    and swaps the cascade in `waybar-style.css` and `swaync-style.css`. The
    repo's rules move after Stylix's, so `12px` overrides `10pt`, a visible
    change;
  - the nixos role lookups reorder `system-path`, `dbus-1` and polkit's
    restart triggers.
  Nesting plain paths four levels deep restored lenovo's drvPath, which
  confirms the cause.

## Options considered

| Option | Five-host parity | Fit here |
|---|---|---|
| A. Status quo | yes | the wiring stays split in two places |
| B. Direct role and HM paths, explicit flake-module list | **no**: all five move, CSS precedence flips | only after #315 pins the order-dependent definitions and the owner accepts the moves |
| C. Self-registering role files (dendritic `flake.modules.nixos.<role>`) | likely (same depth), unmeasured | rewrites every role file into a flake-parts module; buys nothing over D for 7 roles |
| D. **The existing typed table, collapsed and extended; registry and import-tree stay** | **yes, measured** | smallest diff |

Plain `nixosSystem` per host with an explicit module list, and nodes from
`mapAttrs` over the configurations (the deploy-rs README pattern), both fit
inside D.

## Decision

1. **The table is the existing `configurations.nixos` option**
   (`30-configurations-options.nix`). The five `flake-modules/hosts/*.nix`
   files collapse into one value file, `flake-modules/hosts.nix`. It gains
   `deploy` fields and loses `system` and `username`, and `hostDir`
   defaults to the attribute name. The option is not renamed: no reader
   gains, and the rename would touch every consumer.
2. **What belongs in the table:** a field goes in only if something outside
   the host's own evaluation reads it. That covers `roles` (imports cannot
   depend on config), `deploy.*` (read by deploy-rs), and later #291's
   addresses (read by other hosts). Username and feature flags are read only
   inside the host, so they stay in `hosts/<dir>/variables.nix`, which
   `configuration.nix` and tests import as `sam.profile`. Inlining
   `variables.nix` into `configuration.nix` is a separate follow-up.

   ```nix
   configurations.nixos = {
     # deploy-rs runs only on lenovo: its own deploy is a loopback self-push.
     lenovo = { hostDir = "lenovo-21CB001PMX"; roles = [ "base" "laptop" "homelab-server" ]; deploy.hostname = "localhost"; };
     # lenovo, memory-constrained, has crashed building these closures.
     acer-swift = { roles = [ "base" "laptop" "homelab-agent" "runtime-host" ]; deploy.remoteBuild = true; };
     # Same reason; reachable only in its Mon-Fri ~09:00-21:00 power window.
     msi-ms7758 = { roles = [ "base" "homelab-agent" "runtime-host" ]; deploy.remoteBuild = true; };
     # lenovo has no aarch64 builder; untrusted lukas is enough (.drv and sources are CA paths).
     black-pi = { roles = [ "base" "homelab-agent" ]; deploy.remoteBuild = true; };
     # Same reason; rf-lab keeps the closure to cache hits and text derivations, so 1 GiB is enough.
     naked-pi = { roles = [ "base" "rf-lab" "embedded" ]; deploy.remoteBuild = true; };
   };
   ```
3. **Derived:** `nixosConfigurations.<name>` without a `system` argument
   (the flake's `nixosSystem` passes `system = null`, so `hostPlatform`
   decides pkgs; architecture is stated once). `deploy.nodes.<name>` picks
   its activate from `pkgs.stdenv.hostPlatform.system` and emits
   `remoteBuild` only when true.
4. **Unknown user: `sam.profile.username` becomes
   `types.enum (attrNames (import lib/users.nix))`.** A typo then fails at
   the definition, with its file, for every reader, including direct option
   probes. The user lookup reads the option, without `or { }`. The enum is
   preferred to a throw at the lookup because it makes the bad value
   unrepresentable, not merely detected.
5. **The registry stays.** A comment in `20-module-registry.nix` records
   that its depth fixes merge order. The "must include base" assertion stays:
   `laptop.nix` does not import base, so dropping it would be a behaviour
   change.
6. **import-tree stays.** An explicit list of eight files removes one input
   and adds a list to maintain.

Measured on the combined prototype at 72d7bd5: five toplevels and five
deploy-node attrsets (activation drv included) identical. That prototype used
a throw at the lookup; the enum is unmeasured and its step verifies it. Each
step is checked with `just parity` against its own merge base, which since
step P covers deploy nodes as well as toplevels.

## Known fragility

Merge order now rests on import depth, which nobody chose. #315 tracks
pinning the waybar and swaync CSS with `mkBefore`/`mkAfter`. The full set of
order-dependent definitions is unknown. A flake-parts bump (wrapper depth) or
a Stylix bump (its own depth) could flip one, and parity would not catch it:
the drvPath moves with the bump anyway, so an ordering change looks like the
update.

## Consequences

- A sixth host's flake wiring goes from two files to one table entry. Still
  needed: `hosts/<dir>/`, the `just deploy` HOST pattern (checked by
  `test-ssh-known-hosts.py`), its pinned key in
  `modules/core/ssh-known-hosts.nix`, its sops recipient, and optionally the
  `fleetHome` name lists (#291). `just parity` picks the host up on its own.
- Every table entry becomes a deploy node, which is true of all five today.
- Plain paths (B) stay possible once #315 and its successors make order
  explicit.

## Composition with #291

#291 owns the facts (addresses, host keys, cache keys, the k3s server address,
per-host tool choices). It adds typed fields to the same `configurations.nixos`
entries and exposes them to NixOS through one read-only option. #292 adds no
fact fields.

## Not changed

flake-parts, one nixpkgs, no specialArgs, curried `import file inputs.x`,
`fleetHome` and its host-name tests (#291), the `lenovo` attribute vs its
hostname, untyped `sam.userConfig`, `hardware-configuration.nix`, role file
contents, flake-module file names, any deploy.
