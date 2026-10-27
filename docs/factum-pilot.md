# Factum on Lenovo

After switching the Lenovo configuration, the Home Manager profile provides the released Factum
`0.2.0` CLI. The source is pinned to commit `5bb7fa304db7d8ae7d422e8d6356bf06b90d3b41` in
`flake.lock`; `factum --version` reports the release version, not the source revision. Factum's
worker is not packaged, and no Factum command runs automatically or gates a build or merge.

Run Factum from a Rust workspace. For a change, give it a standard unified diff:

```bash
factum --version
factum diagnostics --tool check
git --no-pager diff --no-ext-diff --no-color > /tmp/change.patch
# Include staged changes too, if any:
git --no-pager diff --cached --no-ext-diff --no-color >> /tmp/change.patch
# Untracked files are not included; stage them or intentionally exclude them.
factum review --diff /tmp/change.patch --format json
factum impact --diff /tmp/change.patch
factum tests-for --diff /tmp/change.patch
factum brief --diff /tmp/change.patch
```

`diagnostics`, `review`, `impact`, `tests-for` and `brief` provide advisory, read-only evidence.
`tests-for` lists candidate tests; it does not run them. Keep the project's required test, security,
and review gates. `brief` is capped at 6,144 bytes by default and may omit detailed lane records
present in full `tests-for` output; inspect the full output when those caveats matter. Do not treat
an empty report or selection as proof that a change is correct. An empty `git diff` is not
verification that the worktree is clean or that all intended changes were captured: check staged
changes with `git diff --cached` and account for untracked files explicitly.

The Nix package seeds the ignored `e0308_mismatch/Cargo.lock` fixture deterministically. Its
`cargoBuildFlags` and `cargoTestFlags` target `-p factum`; it does not run the full workspace suite.
The package build passed offline from the flake-locked source using the pinned Rust `1.99.0`
toolchain, including the Factum CLI package tests; this ties the packaged binary and test evidence
to the same release commit.
