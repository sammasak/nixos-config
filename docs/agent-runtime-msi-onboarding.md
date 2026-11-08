# MSI agent-runtime onboarding (#185)

MSI is an intermittent k3s/Ollama worker. Its agent-runtime admission policy
must be based on MSI's own measured headroom while those workloads are active;
do not copy Acer's limits. Keep runtime admission disabled until the evidence
below is reviewed and a policy is committed.

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
If the diagnostics cannot establish safe headroom, leave admission disabled.
Do not change the existing 09:00 wake or 21:00 shutdown schedule to make a test
pass.

## Offline validation and staged rollout

After the host policy and template imports are reviewed, validate the exact
MSI system and template profiles before any activation:

```bash
nix eval .#nixosConfigurations.msi-ms7758.config.sam.agentRuntime.host --json
nix build --no-link --print-build-logs .#nixosConfigurations.msi-ms7758.config.system.build.toplevel
nix build --no-link --print-build-logs .#packages.x86_64-linux.agent-runtime-nspawn
```

The MSI policy change should add a focused eval regression check asserting the
selected template eligibility, concurrency and reserve; the runtime substrate
and Herdr worker prerequisites; and unchanged MSI shutdown, Lenovo wake and
k3s/Ollama semantics. The existing runtime VM test covers generic admission and
lifecycle behavior; host-policy assertions must cover MSI's actual values.

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
