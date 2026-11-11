# Agent runtime: deploy-rs substrate, template profiles, rollout (#140)

Epic [#133](https://github.com/sammasak/nixos-config/issues/133), milestone M3.
How a host gets the ephemeral nspawn agent runtime (`docs/agent-runtime.md`,
`docs/agent-runtime-nspawn.md`) and how its templates change, with deploy-rs
from lenovo and nothing else: no deploy-rs node, profile or switch per
instance, and no CI deployment.

## Two profiles per enabled host

| profile | path on the host | carries | changes when |
|---|---|---|---|
| `system` (exists today) | `/nix/var/nix/profiles/system` | the **substrate**, `nixosModules.agent-runtime-host` with `sam.agentRuntime.host.enable`: `agent-runtime-instance` on PATH, `/etc/agent-runtime/host.json` (the host policy), `/etc/agent-runtime/substrate.json` (schema versions), `/var/lib/agent-runtime`, `/nix/var/nix/profiles/agent-runtime` | the host's NixOS config or the runtime code changes |
| `agent-runtime` | `/nix/var/nix/profiles/agent-runtime/templates` | the host's template manifests (`templates/<name>.json`, each referencing its packages and skills) and an activation that refuses them unless `substrate.json` has the schema they need | a template changes |

Every host imports the substrate module; it does nothing until the host sets
`sam.agentRuntime.host.enable` (the host toplevels are identical to main's with
it imported and off). `flake-modules/70-deploy.nix` gives a node the
`agent-runtime` profile only when its host enables the substrate, with
`profilesOrder = [ "system" "agent-runtime" ]` and the same `deploy` user,
sudo, pinned host key (`StrictHostKeyChecking=yes`), auto and magic rollback
and timeouts as the system profile (and `remoteBuild` on the Pis).

**Why a second profile (the issue's question).** Nothing in the system
closure references a manifest; the host config declares its templates only so
`eligibleTemplates` is checked. A template change therefore moves the
`agent-runtime` profile and not the system: `checks.x86_64-linux.agent-runtime-deploy-compat`
asserts this at evaluation for lenovo and acer-swift (template v1 and v2 give
the same system profile derivation and different template profiles), and the
VM test shows the system generation and `/run/current-system` unchanged across
three template deploys and every instance run. Putting the templates in the
system closure would make each template change a host switch.

## Pinning and GC

- A template profile generation roots its manifests and through them the
  template closures; deploy-rs keeps earlier generations until a GC deletes them.
- `agent-runtime-instance create` roots the manifest it was created from
  (`/var/lib/agent-runtime/<id>/template-root`) next to the run's source roots
  (#136), so an in-flight instance keeps its template's closure across a
  template deploy and `nix-collect-garbage -d`; `destroy` releases both.
- The homelab hosts accept lenovo's closures by signature (`homelab/nix-signing-key`);
  the VM test makes `deploy` a trusted user instead.

## Rollout

Owner commands, from lenovo in `~/nixos-config` after `git pull` (each is an
owner decision; no agent runs them):

1. Enable on a host (msi-ms7758 and acer-swift get the imports, `enable` and `eligibleTemplates` from
   the `runtime-host` role and set only the capacity): in `hosts/<host>/configuration.nix`, import
   the host's template module(s) and set the policy, e.g.
   ```nix
   imports = [ ../../modules/agent-runtime/templates/<template>.nix ];
   sam.agentRuntime.host = {
     enable = true;
     eligibleTemplates = [ "<template>" ];
     maxConcurrentInstances = 1;
     reserve = { memoryMiB = 4096; diskMiB = 20480; };
   };
   ```
   then `devenv tasks run nixos:qa` (it builds `agent-runtime-deploy-compat`
   and the host).
2. Substrate and templates together: the host's usual recipe, which deploys the
   profiles in order, e.g. `just deploy-acer`.
3. Templates alone (no host switch):
   `nix run --inputs-from . deploy-rs -- .#acer-swift.agent-runtime --auto-rollback true --magic-rollback true --activation-timeout 180 --confirm-timeout 30`.
4. Check: `ssh deploy@<host> agent-runtime-instance status` and
   `ssh deploy@<host> nix-env --list-generations -p /nix/var/nix/profiles/agent-runtime/templates`.

## Drain

Running instances keep their template (rooted) and the substrate tool; only
admission is the lever:

1. Remove the template from `eligibleTemplates` (or set
   `maxConcurrentInstances` to the number still running) and deploy the
   `system` profile: `create` refuses new instances, running ones continue.
2. Wait for `agent-runtime-instance status` to show every instance ended;
   export and destroy them (`docs/agent-runtime.md`).
3. Only then set `host.enable = false` and deploy: that removes
   `agent-runtime-instance` from the host.

## Rollback

- **Automatic:** a failed activation of either profile is rolled back by
  deploy-rs (`autoRollback`), and an activation that loses the deployer's
  confirmation is rolled back by `magicRollback`. A template profile refuses
  to activate on a host without a compatible substrate, so templates never
  run ahead of the substrate they need.
- **Rollback finishes on the host, after `deploy` returns.** deploy-rs rolls the
  profile back, deletes the failed generation, and re-activates the previous
  one from the target's `activate-rs` after the deploying client has exited
  (1.1 s later in the VM test). Read `/run/current-system`, not just the exit
  code, before acting on a failed substrate deploy.
- **Manual, templates:** `ssh deploy@<host> sudo nix-env -p /nix/var/nix/profiles/agent-runtime/templates --rollback`
  (instances created afterwards use the previous templates; running ones are
  unaffected).
- **Manual, substrate:** `ssh deploy@<host> 'sudo nix-env -p /nix/var/nix/profiles/system --rollback && sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch'`.

## Failure outcomes

| failure | outcome | where proven |
|---|---|---|
| template activation fails (incompatible substrate, malformed manifest) | deploy-rs rolls the profile back; the previous templates stay active and keep admitting | VM: `tpl-bad` |
| substrate activation fails (a unit does not start) | `switch-to-configuration` fails; deploy-rs rolls the system profile back, deletes the failed generation and re-activates the previous system (after `deploy` has returned) | VM: `broken` |
| SSH to one host fails in a fleet deploy | deploy-rs pushes before it activates: the deploy fails and no host takes the new profile | VM: sshd stopped on `hostb` |
| host offline | the deploy fails within `ConnectTimeout` and changes nothing | VM: `hostb` link down |
| partial fleet after an activation failure on a later node | deploy-rs revokes the nodes it already activated in that run (its default `--rollback-succeeded true`): they return to their previous templates and keep admitting | VM: `tpl-split` (hosta activates, hostb refuses, hosta is revoked) |
| GC during an in-flight job | the instance's template closure stays (rooted); collected after destroy | VM |
| a template deploy while an instance runs | the instance keeps its template; new instances get the new one | VM |
| a reboot | real hosts boot the current system generation; the template profile and the instance records persist (`docs/agent-runtime.md`: ambiguous runs are not replayed) | #138 VM test; a VM test reboot boots the test's own system, so not here |

## Hosts

| host | role here | before enabling |
|---|---|---|
| lenovo | coordinator, deployer; not an instance host while #109's bounded builds are its headroom | owner decision, measured headroom |
| acer-swift | the only k3s worker: the first candidate, behind capacity gates (`reserve`) | owner approval after a quiet window; `just deploy-acer` |
| msi-ms7758 | `rust-pilot` and `claude-coder` (egress `api.anthropic.com`, SOPS subscription token), at most two instances, 2 logical CPUs / 8 GiB memory / 50 GiB disk reserved | owner, Mon-Fri ~09:00-21:00; live CPU/RAM/disk and Ollama/k3s headroom still unverified |
| black-pi | aarch64, builds on itself | untested; the template profile carries `remoteBuild` |

### MSI read-only readiness snapshot

Before an owner-approved activation, collect a timestamped snapshot during MSI's
normal powered-on window. On MSI, these commands report the same logical CPU
count used by runtime admission, available memory, filesystem byte/inode headroom,
and current k3s/Herdr service usage without starting an instance:

```bash
date --iso-8601=seconds
hostnamectl --static
nproc
awk '/^(MemTotal|MemAvailable):/ { print }' /proc/meminfo
df -B1 --output=source,size,used,avail,itotal,iused,iavail / /var/lib/rancher/k3s
systemctl show k3s.service --no-pager --property=ActiveState,MemoryCurrent,CPUUsageNSec,TasksCurrent
systemctl --user show herdr.service --no-pager --property=ActiveState,MemoryCurrent,CPUUsageNSec,TasksCurrent
```

From Lenovo, capture the worker and Ollama placement/load with
`kubectl describe node msi-ms7758`, `kubectl top node msi-ms7758`, and
`kubectl top pods --all-namespaces --sort-by=memory`; retain the Ollama pod's
row and the surrounding workload rows. Compare the measurements with the
declared 2-CPU, 8192-MiB memory and 51200-MiB disk reserves and the 3072-MiB
per-instance cap. Record gaps or peak-time pressure as no-go evidence rather
than treating one quiet snapshot as proof of sustained headroom.

After a separately authorized activation, this read-only preflight reports
whether the host currently meets the policy:

```bash
sudo agent-runtime-preflight \
  --template /nix/var/nix/profiles/agent-runtime/templates/templates/rust-pilot.json
```

A `go` result only permits an operator to decide whether to start the
credential-free pilot.

## Test

`nix build -L .#packages.x86_64-linux.agent-runtime-deploy-test` (acer, heavy
lock): a deployer VM pushes with the flake's deploy-rs to two target VMs with
different policies and one shared template module
(`tests/agent-runtime/deploy-templates.nix`), as `deploy` with sudo and pinned
host keys. The deploy data is prebuilt JSON (`deploy --file`) and every profile
is realised outside the VMs. deploy-rs builds a profile's `drvPath` before it
copies it; the deploy data wraps each profile in a `builtin:buildenv`
derivation (nix's in-process builder, the one nix-env uses), so that build is a
symlink tree written by nix itself: a store binary exec'd as a local build in
the VM is killed (signal 9) under nix's landlock confinement. The system
profiles are the target VMs' own specialisations (`substrate`, `broken`), so
`switch-to-configuration` keeps the test's VM settings.
