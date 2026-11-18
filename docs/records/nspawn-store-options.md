# nspawn environments: store options tried

Moved unchanged from `docs/nspawn-workers.md` on 2026-11-18; written 2026-11-11 to 13. Option 1 is what runs
(`docs/nspawn-workers.md`, "Made of").

1. **Shared host daemon (what runs).** A guest sees the host `/nix/store` read-only and builds and fetches through
   the host's nix daemon. It is the only option that makes a fresh clone's `devenv shell` work, and a path any
   guest builds is there for all of them. The price is that the daemon is a write path from guest to host store.
2. **Read-only store, no daemon socket** (branch `feat/no-daemon-socket`). Running binaries, `nix eval`, locked
   github flakes and a `devenv shell` in an already-entered project work. A fresh clone's `devenv shell` fails: it
   must add a new `devenv-files.drv` to the store, which nothing can do without a writable store.
3. **Per-environment `local-overlay` tier** (branch `feat/store-overlay`). Fails on a live host store: the lower
   store opens the host db immutable and so misses everything in its WAL, so paths the host registered since the
   last checkpoint, the guest's own system among them, are "not valid" and Home Manager fails. It would need a
   frozen lower store (a snapshot), not the live one. Both branches stay unmerged as the record.
4. **Root-built fetcher-cache seed for a new `rootInGuest` environment** (branch `feat/fetch-cache-seed`, dropped).
   It warmed a new environment's empty `~/.cache/nix`, but each repo pins its own nixpkgs (six distinct revisions
   across nixos-config, factum and herman), so a seed made from one lock misses the others. Measured: a shared nixpkgs
   pin alone shares 13 of 262 store paths (the toolchain closure is keyed by nixpkgs and rust-overlay together), and
   copying an older pin set breaks a repo that needs a newer Rust. The lever is one pin set (nixpkgs, rust-overlay,
   devenv, git-hooks) owned by devenv-platform at the newest revision any repo needs.
