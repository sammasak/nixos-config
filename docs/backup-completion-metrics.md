# Backup completion metrics

The existing Edge dashboard shows when Authentik's timers fired and whether their units are
failed. A timer trigger does not establish successful completion. The completion metrics in
#564/#600 supplement those signals for four existing jobs:

| Unit | Existing validation, after which success is recorded |
|---|---|
| `authentik-backup` (acer) | `pg_restore --list` reads the archive (`archive_list`) |
| `authentik-offhost` (lenovo) | The pulled archive passes `pg_restore --list` (`archive_list`) |
| `llm-gateway-backup` (acer) | Existing scratch SQLite restore/integrity and table-count check (`scratch_restore`) |
| `open-webui-backup` (acer) | Existing scratch DB/uploads restore and consistency check (`scratch_restore`) |

Neither class proves the full #564 clean-environment disaster recovery contract. In particular,
a recently completed off-host copy could have copied an old source dump. These metrics do not
prove the source archive's age, retention, encryption, contents or recovery readiness.

A post-success hook reads systemd's successful main-process exit status and monotonic start/end
timestamps. It atomically records completion and duration in that unit's private
`/var/lib/backup-metrics/<unit>/success.json`, mode 0600. systemd creates each job directory
with the existing service identity and mode 0700. The hook has a ten-second timeout (two-second
kill grace); failure is ignored by systemd so telemetry failure does not fail a valid backup.
Failed or condition-skipped backups do not overwrite the previous success.

A root oneshot scans only declared job metadata every five minutes, after a one-minute boot
delay, and atomically writes mode-0644 `/run/node-exporter-textfile/backup.prom`. This survives
reboots through persistent per-job state; the exposition itself is recreated after boot.
The collector has a read-only system filesystem except the existing textfile output directory.
It reads only small regular metadata files and refuses symlinks/FIFOs. It does not read
databases, backup archives, uploads or secrets. No exporter/port or new backup
implementation is added. Labels are bounded configured backup names and validation classes.

- `homelab_backup_metadata_available{backup,validation}` is 1 for valid metadata and 0 for
  missing/invalid metadata. This measures availability of evidence, not backup health.
- `homelab_backup_last_success_timestamp_seconds{backup,validation}` is the most recent
  recorded successful main-process completion, reconstructed from monotonic elapsed time
  and the wall clock. It is absent until a real instrumented run completes; no timer-based
  backfill and no zero success timestamps. Clock steps can affect wall-time reconstruction.
- `homelab_backup_last_success_duration_seconds{backup,validation}` measures that successful
  main process, not the most recent failed attempt or post-hook/collector time.
- `homelab_backup_collector_last_success_timestamp_seconds` measures metadata-scan freshness.
  Per-backup missing/corrupt state can coexist with a successful collector scan.

The Edge dashboard displays all four. Keep the existing failed-unit and timer panels. A recent
completion timestamp alone can remain visible when later backups fail; compare age and current
failed-unit state. Missing/corrupt/future metadata is explicit availability 0 with success values
absent. A failed collector preserves its previous exposition; use collector age and existing
textfile scrape-error metrics to detect that condition. No new paging policy is inferred here.

## Verification and rollout

The collector reserves 64 MiB through `MemoryMax`. Lenovo's user-slice ceiling is
8336 MiB (2084 MiB swap), allocating that reservation from its previous ceiling.
The declared caps plus protected service floors total 15648 MiB against 15667 MiB
RAM, preserving the existing 19 MiB budget margin. The measured 7.6 GiB user
workload still fits. The memory-budget assertion and build-bounds regression
remain required: adding the collector without this allocation exceeds the budget.

The `checks.x86_64-linux.backup-metrics` check exercises the real Python writer/collector with
synthetic systemd results, including failed/killed/unfinished executions, timeouts, corrupted or
future metadata, persistent old success, bounded labels, permissions and emitted Prometheus
format. It also reads evaluated service wiring for all four units and preserves existing users
and backup state directories. The dashboard check consumes the actual fixture exposition as
its metric catalog. `checks.x86_64-linux.backup-metrics-systemd` boots an isolated VM with a
synthetic service to check the real post-success lifecycle, state ownership, private metadata,
public exposition, failed/skipped runs and a metric-write failure that must leave the backup
successful. Neither fixture proves post-hook execution on a deployed production host.

After reviewed source and full QA, named acer/lenovo/black-pi activation remains an operator
step. Do not restart a production backup just to manufacture a receipt: allow the next approved
scheduled run. Before that run metadata is unavailable by design. Verify completion against the
unit journal and the new timestamp, validation class and duration, then check the five-minute
collector receipt and rendered Edge panels. Record any skipped/failed run honestly. Restore
trials, external storage, secret changes and actual backup data movement remain separate #564
owner gates. Rollback removes instrumentation; it does not delete backup data or retained
metadata automatically.

## Correctness tooling

The `checks.x86_64-linux.backup-metrics` derivation runs Ruff correctness and
bug-pattern rules (`E4,E7,E9,F,B`), strict mypy on the operational helper, nine
behaviour tests against the real helper and evaluated unit wiring, and `promtool`
on the generated exposition. The helper has typed IO/validation boundaries;
untrusted JSON still requires explicit runtime validation. These checks do not
replace the isolated systemd VM test, full QA or real backup/restore evidence.
