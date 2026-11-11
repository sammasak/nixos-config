# MSI agent-runtime onboarding (#185)

MSI is an intermittent k3s/Ollama worker. Its agent-runtime admission policy
must be based on MSI's own measured headroom while those workloads are active;
do not copy Acer's limits. #191 (merged) sets a bounded `rust-pilot` policy,
which must be checked against MSI's measured headroom before an owner deploys
it. This branch adds diagnostics only and does not change host policy.

## Read-only capacity snapshot

Run this on Lenovo, or another owner-approved machine on the key's allowed
source network, during MSI's normal Mon–Fri 09:00–21:00 power window. The
pinned SSH identity is source-restricted; Acer Swift is not an authorized route.
Do not change the key restriction or firewall to collect this snapshot:

```bash
ssh -o BatchMode=yes msi-ms7758 'bash -s' \
  < scripts/agent-runtime-msi-capacity-report.sh
```

The script reads:
- the host's current generation (`readlink /run/current-system`) and load (`uptime`);
- CPU and memory totals, filesystem capacity and mounts;
- the k3s service counters;
- Herdr as the Home Manager **user** unit it is (`loginctl show-user <user> -p Linger`,
  `systemctl --user -M <user>@ is-active herdr.service`; the user defaults to `lukas`,
  `'bash -s -- <user>'` names another);
- running `agent-runtime-*` instance units (names only);
- the shutdown timer's state and next trigger (`systemctl list-timers msi-scheduled-shutdown.timer`);
- top process memory and the systemd cgroup snapshot. It prints no environment variables, command arguments, credentials,
model contents or file listings. Save the output with the measurement time and
record whether k3s and Ollama were carrying their normal workload.

Ollama is **not** a host service here: it is the k3s pod `llm/ollama-msi`
(`ollama.service` reads inactive), and the 8 GiB memory reserve is calibrated to
that pod's limit. A k3s agent has no admin kubeconfig, so take the cluster side
from Lenovo in the same window:

```bash
kubectl get node msi-ms7758 -o wide
kubectl top node msi-ms7758
kubectl get pods -A -o wide --field-selector spec.nodeName=msi-ms7758
kubectl -n llm get pod -l app=ollama-msi -o jsonpath='{range .items[*].spec.containers[*]}{.name} {.resources}{"\n"}{end}'
kubectl -n llm top pod
```

Together the two outputs give the full #185 snapshot: generation, load,
node/pod usage, the Ollama pod's requests and limits, the Herdr state and the
shutdown timer. Repeat at a
busy period before setting `reserve` or `maxConcurrentInstances`.

The MSI policy should admit only explicitly named templates, remain within the
measured CPU/memory/disk headroom, and keep enough reserve for k3s and Ollama.
If the diagnostics cannot establish safe headroom, do not deploy the candidate
admission policy. Do not change the existing 09:00 wake or 21:00 shutdown
schedule to make a test pass.

## Declarative prerequisites on `origin/main`

On `main` since #191 (`9df8c53`, 2026-11-09), `hosts/msi-ms7758/configuration.nix` declares:

- `sam.agentRuntime.host.enable = true`, `eligibleTemplates = [ "rust-pilot" ]`,
  `maxConcurrentInstances = 2` and `reserve = { cpus = 2; memoryMiB = 8192; diskMiB = 51200; }`;

The rest, from pure evaluation at `018e881` (2026-11-08), is unchanged by #191:

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
Herdr is active or reachable on the installed MSI generation (the script's
Herdr line is that live check). It also confirms that no worker bypass
permission (`sam.herdr.worker`) or remote Herdr registration is currently
declared. Keep those separate from host capacity and live acceptance.

## Offline validation and staged rollout

#191 supplies the MSI policy-evaluation check: it asserts the candidate
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
- A credentialed `claude-coder` run on MSI (credential-free starts, verified exports and clean
  teardowns are evidenced on #186).
- Offline visibility during the scheduled shutdown and recovery after the next
  permitted wake, observed from Lenovo.
