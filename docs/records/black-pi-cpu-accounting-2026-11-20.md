# Black-pi CPU accounting: kernel candidate

Tracking: [#601](https://github.com/sammasak/nixos-config/issues/601), under
[#600](https://github.com/sammasak/nixos-config/issues/600). This is a diagnosis
and source compatibility receipt, not a compiled or activated kernel fix.

## Reproduction

At 23:29–23:30 UTC on 19 November, seven read-only samples bracketed
`/proc/stat` with `/proc/uptime`, five seconds apart. UTC timestamps provided
an independent elapsed-time comparison. No workload or host setting changed.
Raw artifacts remain private; aggregate evidence is recorded here.

| Observation | Result |
|---|---|
| Observation span | 30.16 seconds |
| CPUs | Four, online 0–3 |
| Userspace conversion | `getconf CLK_TCK`: 100 ticks/second |
| Non-guest accounted time | 137.77 CPU-seconds; 1.14199 seconds/second per CPU |
| Aggregate interval rates | 4.5567–4.5857 CPU-seconds per elapsed second |
| Idle alone | 4.3207–4.4732 CPU-seconds per elapsed second |
| Individual CPU interval rates | 1.1093–1.1710 seconds/second |
| Maximum read bracket | 0.01 seconds |
| Wall/uptime interval comparison | Agreement within sampling/uptime rounding |

Sum the first eight CPU fields only: user, nice, system, idle, iowait, irq,
softirq and steal. Guest/guest_nice are already included in other modes.
Divide tick deltas by USER_HZ and elapsed time; do not divide by kernel HZ.

The running kernel is 7.2.10 with `arch_sys_counter`, HZ=250,
`CONFIG_NO_HZ_FULL`, generic virtual accounting and IRQ-time accounting.
The runtime nohz_full and isolated CPU sets are empty. This does not disable
ordinary dyntick-idle accounting. NTP reports synchronized, which alone does
not prove clock correctness.

Excess time is present below Prometheus and node-exporter. Read skew is too
small to explain its magnitude. The measurement does not establish which
kernel mechanism caused it. Preserve the raw negative busy signal and the
accounted-time diagnostic; normalization/clamping would hide the symptom.

## Exact configured source

Current main at `7de09c6e` selects kernel 7.2.10. Reinspect it with:

```sh
nix eval --json .#nixosConfigurations.black-pi.config --apply \
  'c: let k = c.boot.kernelPackages.kernel; in { version = k.version; source = toString k.src; patches = map toString (k.patches or []); }'
```

The archive is `linux-7.2.10.tar.xz`, hash
`sha256-L+qnBFPpH1Qb5qXJB42BaOCBr0Wj2XGAVIUFOM/y6/M=`.
Fetching it with Nix's expected-hash check produced exactly the source store
path selected by the configuration.

The package applies `bridge-stp-helper.patch`, `request-key-helper.patch` and
`randstruct-provide-seed-5.19.patch`; `boot.kernelPatches` is empty. Replayed
these with Nix's default GNU `patch -p1`: the bridge patch uses fuzz 2 and an
offset, the key-helper patch an offset, and all three succeed. They touch no
CPU-accounting files. This existing patch behavior was not changed.

## Candidate and remaining proof

The upstream [idle-overlap fix](https://github.com/torvalds/linux/commit/96a494c9cfd8f4bb7b1a7a70275426db71cf98aa)
addresses overlapping tick and dyntick-idle accounting. Its
[warning correction](https://github.com/torvalds/linux/commit/b327e63683a2b894b500027375342c25222b58ef)
handles an edge case in the first fix. Consider both, in that order.

The configured source contains the dyntick accounting path and lacks the
candidate overlap handling. After replaying all three package patches, both
upstream patches pass sequential `git apply --check` and apply successfully
to the affected files. This proves textual compatibility only. It does not
prove compilation, the exact running binary's source, causality or recovery.

Next: prepare and build a candidate against this exact kernel configuration
without activation. A later explicitly approved black-pi boot must repeat
the raw measurements over longer matched idle and mixed-workload windows,
report tick/read uncertainty, and verify network, storage and monitoring
health. Keep the prior boot generation available. Reject the candidate if
accounting remains invalid or host/service behavior regresses. Kernel changes
and a reboot have not been performed by this investigation.
