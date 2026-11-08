# MSI agent-runtime onboarding (#185)

MSI is an intermittent k3s/Ollama worker. Its agent-runtime admission policy
must be based on MSI's own measured headroom while those workloads are active;
do not copy Acer's limits. PR #191 proposes a bounded `rust-pilot` policy, but
that candidate must be checked against MSI's measured headroom before an owner
deploys it. This branch adds diagnostics only and does not change host policy.

## Read-only capacity snapshot

From a workstation with the existing pinned SSH identity, during MSI's normal
Mon–Fri 09:00–21:00 power window, run:

```bash
ssh -o BatchMode=yes msi-ms7758 'bash -s' \
  < scripts/agent-runtime-msi-capacity-report.sh
```

The script reads CPU and memory totals, filesystem capacity and mounts, active
service state/resource counters, top process memory and the systemd cgroup
snapshot. It prints no environment variables, command arguments, credentials,
model contents or file listings. Save the output with the measurement time and
record whether k3s and Ollama were carrying their normal workload. Repeat at a
busy period before setting `reserve` or `maxConcurrentInstances`.

The MSI policy should admit only explicitly named templates, remain within the
measured CPU/memory/disk headroom, and keep enough reserve for k3s and Ollama.
If the diagnostics cannot establish safe headroom, do not deploy the candidate
admission policy. Do not change the existing 09:00 wake or 21:00 shutdown
schedule to make a test pass.

## Declarative prerequisites on `origin/main`

Pure evaluation at `018e881` (2026-11-08) reports:

- `sam.agentRuntime.host.enable = false` and `eligibleTemplates = []`;
- `sam.profile.devTools = true` and `users.users.lukas.linger = true`;
- Home Manager declares the Herdr user service under `default.target`;
- `sam.herdr.worker.enable = false` and `sam.herdr.machines = []`;
- MSI's self-shutdown timer, Lenovo's MSI wake timer and MSI's k3s service are
  enabled.

The evaluated timers are `Mon-Fri 21:00` on MSI and `Mon-Fri 09:00` on Lenovo,
both with `Persistent=false`. The MSI shutdown service stops `k3s.service`,
waits five seconds and powers off. MSI retains Cilium and the worker-pool label
plus `sammasak.dev/intermittent=true:NoSchedule` taint. These are the baseline
semantics the onboarding regression must preserve.

This proves the checked-in Herdr server and linger configuration, not that
Herdr is active or reachable on the installed MSI generation. It also confirms
that no worker bypass permission or remote Herdr registration is currently
declared. Keep those separate from host capacity and live acceptance.

## Offline validation and staged rollout

PR #191 supplies the MSI policy-evaluation check: it asserts the candidate
`rust-pilot` eligibility, two-instance cap, 2-CPU/8-GiB/50-GiB reserve, no
network or credentials, and unchanged shutdown, k3s worker and auto-reboot
settings. It also adds generic aggregate CPU/memory/disk admission checks. The
policy is declarative; it is not evidence that MSI has the required live
headroom. This branch does not duplicate or modify those reviewed checks.
The existing `agent-runtime-preflight` checks whether a proposed instance fits
the host policy at run time; this report complements it with workload and
filesystem measurements needed to assess that policy.

Before any activation, validate the exact MSI system and template profiles:

```bash
nix eval .#nixosConfigurations.msi-ms7758.config.sam.agentRuntime.host --json
nix build --no-link --print-build-logs .#checks.x86_64-linux.agent-runtime-msi-pilot
nix build --no-link --print-build-logs .#nixosConfigurations.msi-ms7758.config.system.build.toplevel
nix build --no-link --print-build-logs .#packages.x86_64-linux.agent-runtime-nspawn
```

The existing runtime VM test covers generic admission and lifecycle behavior;
the host-policy assertions cover the candidate values. A live measurement still
needs to confirm they preserve MSI's actual k3s/Ollama workload headroom.

Live activation remains an owner decision. After a reviewed PR and explicit
go-ahead, `just deploy-msi` uses deploy-rs with pinned host-key verification,
automatic rollback and the existing activation timeout. Run it only during the
normal power window. If activation fails, deploy-rs rolls back; if a later
operator rollback is needed, use the documented NixOS generation rollback on
MSI with owner approval. The first live fixture must be credential-free and
must leave k3s/Ollama and the power schedule intact.

## Still requires live evidence

- MSI's measured peak k3s/Ollama resource use and writable filesystem headroom.
- The installed Herdr server, user linger and worker availability.
- One credential-free runtime start, verified export and clean teardown.
- Offline visibility during the scheduled shutdown and recovery after the next
  permitted wake, observed from Lenovo.
