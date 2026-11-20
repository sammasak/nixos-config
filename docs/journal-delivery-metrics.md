# Host-journal delivery counters

Tracking: [#600](https://github.com/sammasak/nixos-config/issues/600) and
[#602](https://github.com/sammasak/nixos-config/issues/602).

The 20 November baseline found that Prometheus only scraped acer's OTLP Alloy
writer. The five host-journal collectors had useful loopback counters but no
delivery-counter scrape. Loki receiving logs does not establish lossless delivery.

`journal-metrics.nix` collects a bounded allowlist from the existing loopback Alloy
endpoint about once a minute. The existing node-exporter textfile collector reads
`/run/journal-metrics/journal.prom`; no new port or network source is admitted.
The Loki Ingestion dashboard keeps OTLP and host-journal results separate.

| Metric | Meaning |
|---|---|
| `homelab_journal_reader_lines_total` | Journal entries read before filtering |
| `homelab_journal_writer_sent_entries_total` | Entries the writer successfully sent |
| `homelab_journal_writer_retries_total` | Retried export batches, which may later succeed |
| `homelab_journal_writer_dropped_entries_total{reason}` | Entries discarded by the writer |
| `homelab_journal_filtered_lines_total{reason}` | Intentional privacy/noise filtering before export |
| `homelab_journal_metrics_collection_success` | Whether the last loopback collection parsed the required counters |
| `homelab_journal_metrics_collection_timestamp_seconds` | Last attempt time, including failed attempts |

Only the configured journal reader, processor and writer components are accepted.
Endpoint, tenant and component labels are removed; filter/export reasons are fixed
allowlists with future reasons aggregated as `other`. At most 17 series per host
are emitted. Source counters reset with Alloy; use `rate`/`increase` before
aggregation. Missing filter reasons are not initialized to zero. Approximate
five-minute rates reflect the one-minute collection cadence.

The helper caps its response at 256 KiB and its HTTP request at five seconds.
Transport/schema failures atomically replace counters with collection success 0;
the systemd service also fails. A newly started writer may not expose required
tenant counters until its first batch: this is unavailable evidence, not observed
loss or a reason to synthesize zeros. A killed or stopped collector can leave old output,
so success must be paired with age below 180 seconds and a current successful node
scrape. This age is collection freshness, not delivery latency. Planned-off hosts
remain unknown. A filesystem failure cannot promise a newly written failure gauge.

The oneshot uses a dedicated stable system account, a 16 MiB/no-swap cap and
loopback-only egress. Its preserved runtime directory is shared read-only with
node-exporter through 0755/0644 filesystem permissions. A preserved DynamicUser
directory would be hidden under `/run/private`, so it cannot serve this purpose. Lenovo's
user ceiling reserves those 16 MiB from its previous allocation (8336 to 8320 MiB;
swap 2084 to 2080 MiB), preserving service floors, daemon caps and the existing
19 MiB declared margin. This slightly reduces user headroom and does not solve its
historical OOM. Other host budgets must pass evaluation too.

## Acceptance

The focused `checks.x86_64-linux.journal-metrics` check runs the actual helper
against a local HTTP fixture, malformed/oversized/error responses and the evaluated
units, then validates actual output with promtool. The dashboard catalog consumes
that same output. Full QA and independent review precede source publication.

A bounded ASUS helper test against its real loopback Alloy completed successfully
under the 16 MiB cap: 17 ms runtime, 16 ms CPU and 3.7 MiB peak, with no swap.
Its output stayed in a private test directory; it was not added to live node-exporter.
An equivalent stable-user transient sandbox also passed twice, including restart,
with the proposed filesystem/network protections and a 3,948,544-byte memory peak.
The actual node-exporter account could read the 0644 output through the ordinary
0755 runtime directory after both runs. It used the existing stable `lukas` account,
not the future dedicated account; no users or production units were changed. The
initial test harness omitted PATH and failed before collection; adding the runtime
PATH supplied by the real Nix wrapper resolved that harness error. Test units/files
were cleaned up and their failed state cleared. This is not timer, final dedicated
account or Prometheus delivery acceptance.

After approved host activation, record the source SHA and running generation, then
confirm all five expected known-on hosts with:

```promql
homelab_journal_metrics_collection_success{job="node-exporter"}
time() - homelab_journal_metrics_collection_timestamp_seconds{job="node-exporter"}
count by(node) (homelab_journal_reader_lines_total{job="node-exporter"})
```

Compare raw loopback and exposed counters in the same sampling window; verify
reader/sent/retry/drop/filter panels separately. Check collector memory, scrape
duration, textfile errors and new series against #600's existing budgets. Revert on
lost privacy filtering, unreadable files, collector OOM or operational regression.
Zero writer drops cannot detect all crash losses: Alloy's in-memory queue, journal
retention gaps and missing pre-reader events remain outside these counters. No
new paging threshold or lossless-delivery claim is introduced.
