# ADR: Keep the hosts table and role registry; no dendritic migration

Status: accepted 2026-11-17, with amendments, by the coordinator on the owner's delegation, after a second-agent
consultation. Analysis read at main `77e7c53`. Sources: the architecture-lane comment on #295
(https://github.com/sammasak/nixos-config/issues/295#issuecomment-6944337568) and the decision comment
(https://github.com/sammasak/nixos-config/issues/295#issuecomment-6944477081). No PR carried it; this file is its
first copy on main.

## Decision

The repo keeps flake-parts with the typed hosts table (`flake-modules/hosts.nix`) and the `flake.modules` role
registry (`flake-modules/module-registry.nix`), as `docs/flake-wiring.md` describes. Modules are not converted into
dendritic aspects, in part or in full.

## Why

- The repo already uses the dendritic parts that pay off at this size: flake-parts, class-checked `flake.modules`,
  import-tree over `flake-modules/`, no `specialArgs`, and "import is the switch".
- Merge order rests on import depth (`docs/flake-wiring.md`, "Known fragility"). Any layout change moves every host's
  toplevel, so `just parity` could not tell an intended move from a reordering.
- No source measured evaluation speed either way, so speed is not a reason for or against.

## Options compared (17 Nov, estimates unless stated)

| | (a) No change | (b) Cross-class feature aspects | (c) Full dendritic |
|---|---|---|---|
| Files touched | 0 | about 20 to 25 | about 150, plus tests and docs |
| Merge-order risk | known only (#315) | Home Manager modules change depth; reordering likely on every devTools host | every toplevel moves; parity cannot separate intended moves |

Chosen: (a). Option (b), the "in part" path, rested on estimates only; nobody built or measured it.

## When to revisit

Only when a named, measured problem exists that the current layout cannot solve. Making merge order explicit is not
by itself a trigger: #315 (now closed, the waybar and swaync CSS pinned with `lib.mkBefore`) was scheduled on its own
merit as a build-time gap, not as a step toward a migration. The draft's condition "revisit after #315 and its
successors" was struck by this amendment.
