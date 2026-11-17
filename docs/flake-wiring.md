# Flake wiring: the hosts table and the module registry

`flake-modules/hosts.nix` is one typed table (option in `hosts-option.nix`): each entry holds `roles`, and `deploy`
fields (`hostname`, and a required `remoteBuild`). From it `nixos-configurations.nix` derives `nixosConfigurations`
and `deploy.nix` derives the deploy-rs nodes. There are six entries today. Architecture is stated once, by
`nixpkgs.hostPlatform` in each host's hardware scan (the Pis: `modules/hardware/pi-sd-image.nix`), and `sam.profile.username` is an enum of `lib/users.nix`, so a
typo fails at its definition. A new host's checklist is "Adding a New Host" in `CLAUDE.md`.

A field goes in the table only if something outside the host's own evaluation reads it (`roles`, since imports cannot
depend on config, and `deploy.*`). A fact read by two or more modules goes in `sam.fleet` (`modules/core/fleet.nix`),
not in the table: nothing at flake level reads an address, and a module under `core/system.nix` also reaches worker
guests and the runtime-host VM test. A fact with one reader stays in its reader.

## Why the registry's depth matters

`flake-modules/module-registry.nix` only turns a role or home file name into a path, but its nesting decides merge
order. The module system collects imports breadth-first, so import depth decides where definitions land in list and
lines merges, and flake-parts nests each `flake.modules` entry three levels deep. Importing the plain paths instead
moves every host's toplevel: reordered `system-path`, `home-manager-path` and fish completions, and a swapped cascade
in the waybar and swaync CSS where the repo's rules land after Stylix's. The registry and its lookups
(`config.flake.modules.nixos.role-<name>`, `...homeManager.<name>`) therefore stay, and `just parity` is the check that
the order did not move.

## Known fragility

Merge order rests on import depth, which nobody chose. The waybar and swaync CSS are pinned with `lib.mkBefore`
(`modules/desktop/common/programs/waybar/minimal.nix`, `swaync/default.nix`), but the full set of order-dependent
definitions is unknown. A flake-parts bump (wrapper depth) or a Stylix bump (its own depth) can flip one, and parity
cannot catch it: the drvPath moves with the bump anyway, so an ordering change looks like the update.

`sam.userConfig` is a typed submodule (`git.userName`, `git.email`, `sshKeys`): it was `types.attrs`, which merged by `//`,
silently dropping keys, and did not discharge `mkDefault`/`mkIf`; `scripts/test-typed-interfaces.py` keeps it typed.

The migration plan and its evidence: `git log -- docs/flake-wiring.md`.
