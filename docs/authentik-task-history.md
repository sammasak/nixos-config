# Blueprint task history

Authentik 2026.5.6 can delete a task after its broker consumer has taken the
message but before the first task-log insert. A missing-file blueprint is
removed by `clear_failed_blueprints`; Django's generic relation cascades that
deletion to its tasks. The middleware then inserts a log referencing the deleted
task and PostgreSQL rejects it with SQLSTATE 23503. Investigation and live
acceptance are tracked in #614.

The package patch in
`modules/homelab/authentik/retain-blueprint-task-history.patch` keeps task parents
when a blueprint is deleted. The broker still owns task expiry and deletes the
associated task logs. This changes deletion behavior without adding a table or
migration. A task may retain a generic reference to a blueprint that no longer
exists. The existing exact Authentik version assertion requires reconsideration
when nixpkgs updates the package.

`modules/homelab/authentik.nix` builds the patched Django package into the Python
environment shared by migration, worker, server, and the `ak` helper. It keeps
the existing Python ABI and Go/Rust binaries. The shared working directory and
Python import path must remain consistent; changing only an interactive shell
would leave the worker vulnerable.

Run the focused regression under the shared heavy-work lock:

```sh
flock -o /run/work-locks/heavy-work.lock \
  nix build --no-link .#checks.x86_64-linux.authentik-task-history
```

The check runs the original and patched packages in separate fresh databases
under the Nix build's temporary directory. PostgreSQL accepts only private Unix
socket connections. The original package must reproduce the exact FK failure
three times. The patched package must preserve the consumed task, create its
logs, acknowledge it to `done`, and purge the task and logs through the broker
after forced ageing. Rollback and successful-blueprint controls must pass too.
An import-origin assertion checks which package was actually loaded, and an
evaluated-unit assertion holds the shared import wiring.

The check establishes the isolated race and purge behavior. Forced ageing does
not prove elapsed retention or production worker scheduling. Live acceptance
still requires the tested generation on Acer, verification of the Go/Rust
startup import paths, and an observed recurrence window without the FK errors.
Do not claim that source validation or a merge establishes deployed remediation.
