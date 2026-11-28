# Native NixOS integration testing

Use the native test driver's systemd-nspawn backend for new service
integration tests. Existing QEMU checks retain their assertions until an
equivalent container check is proven. Track the first conversion in
[#967](https://github.com/sammasak/nixos-config/issues/967) and driver workflow
in [#965](https://github.com/sammasak/nixos-config/issues/965).

## First opt-in check: post-deploy-check

`packages.x86_64-linux.post-deploy-check-nspawn` uses exactly the same
fixture, actual `scripts/post-deploy-check.sh` and five subtests as
`checks.x86_64-linux.post-deploy-check-vm`. The only fixture change is
the machine backend. Packages are evaluated but not built by the
scheduled flake gate; this native check is explicit until equivalence
and cost are recorded. No KVM requirement is intended.

The [pinned driver run module](https://github.com/NixOS/nixpkgs/blob/fe13242281a67641c0102cdb1087f0ebe586c7df/nixos/lib/testing/run.nix)
requires `nixos-test` and `uid-range` for pure containers, with
auto-allocated UIDs and daemon cgroup support. No mixed VM network means
no new `devnet` capability or /dev/net sandbox mount. Verify actual
eligible builder features, free capacity and host lock first; don't
advertise features as a workaround, add privileges to slots, or wake a
sleeping host. If unsupported, record UNTESTED and the blocker.

From the exact checkout, one command per lock:

```sh
jq -r '.nodes.nixpkgs.locked.rev' flake.lock
flock -o -w 900 /run/work-locks/light-work.lock nix eval --json .#packages.x86_64-linux.post-deploy-check-nspawn.config.requiredFeatures \
  --apply 'features: builtins.filter (name: features.${name}) (builtins.attrNames features)'
flock -o /run/work-locks/heavy-work.lock nix build -L --no-link .#packages.x86_64-linux.post-deploy-check-nspawn
```

Expected: real systemd unit state, skipped unit and long-running oneshot
pass, restart-wait/restart-activation and failed unit fail with the
specific script output, recovery passes. Container-specific failed units
or permissions are a compatibility finding, not reason to weaken the
assertions. Build output alone is not proof if the result was substituted;
record actual execution or matching trusted cached result separately.

## Drive the test and diagnose one failure

```sh
flock -o /run/work-locks/heavy-work.lock nix build -L --out-link result-native-driver .#packages.x86_64-linux.post-deploy-check-nspawn.driver
```

On our [pinned interactive driver](https://github.com/NixOS/nixpkgs/blob/fe13242281a67641c0102cdb1087f0ebe586c7df/nixos/doc/manual/development/running-nixos-tests-interactively.section.md),
native nspawn interactive driving requires host root. Resolve the store
path of `result-native-driver/bin/nixos-test-driver` and hand the
operator that exact executable plus `--interactive`. Operator holds
the same heavy lock through the foreground run. For the already authorized
root operator only, from the disposable checkout:

```sh
driver=$(readlink -f result-native-driver/bin/nixos-test-driver)
flock -o /run/work-locks/heavy-work.lock "$driver" --interactive
```

No sudo grant to agents;
if no root session is authorized, use unattended build logs and record
interactive UNTESTED. No production activation or live worker access.

At the test driver's Python prompt on the disposable node:

```python
from datetime import timedelta

start_all()
machine.wait_for_unit("multi-user.target", timeout=timedelta(seconds=45))
print(machine.execute("systemctl is-system-running", timeout=timedelta(seconds=10)))
print(machine.execute("systemctl --failed --no-pager", timeout=timedelta(seconds=10)))
print(machine.execute("systemctl start waiting.service", timeout=timedelta(seconds=10)))
machine.wait_until_succeeds("systemctl show -p SubState --value waiting.service | grep -qx auto-restart", timeout=timedelta(seconds=45))
print(machine.execute("systemctl show -p ActiveState -p SubState waiting.service", timeout=timedelta(seconds=10)))
print(machine.execute("journalctl -u waiting.service -b --no-pager -n 30", timeout=timedelta(seconds=10)))
```

For this controlled failure, after observing the fixture's auto-restart
state in the guest, execute the
script as its unprivileged fixture user (the resolved store script path
is in the built driver's test-script). Before stopping it the check
must exit 1 with the restart-loop message; after stopping it the
checker must pass. For a real red test assertion, use a temporary
isolated checkout changing only one expected result in the fixture,
not production behavior. Capture the exact red reason, restore the
fixture and run the unmodified head unattended. Do not commit a
deliberately broken assertion or weaken the existing tests.

`test_script()` runs the script in the driver; use a fresh session
for the whole script after manual steps and diagnose individual
commands on failure (a failing script may exit). Quit and confirm
container cleanup. Do not enable the SSH backdoor or debug hook by
default. Building the driver or an interactive result is not a pass
for the unattended test.

## Compare and retain

On an admitted host with existing legacy VM support, use the same head
and compare the existing QEMU result (reuse matching recorded evidence
where available) with the new native result. Keep its five expected
subtests, security/identity and recovery behavior identical. Record
host, backend, exact command, input pin, head, required features,
exit, observed build/runtime/peak memory if available, and cleanup.
Use existing gate-step/cache records for normal runs; don't create a
benchmark harness or a second scheduled gate. If equivalent and lower
cost, propose replacing the legacy check in a later small PR; if not,
name the unsupported contract and retain the VM. Also record
`evaluated`, `driver-built`, `debugged`, `assertions-passed` and
`UNTESTED` separately. Source green is not live service acceptance.
