#!/usr/bin/env python3
"""Snapshot existing monitoring APIs for the issue-tracked improvement cycle."""
import argparse
import datetime
import json
import sys
import urllib.parse
import urllib.request


PROMETHEUS_QUERIES = {
    "scrape_current": "up",
    "scrape_samples_24h": "count_over_time(up[24h])",
    "systemd_collector_success": "node_scrape_collector_success{collector=\"systemd\"}",
    "scrape_24h": "avg_over_time(up[24h])",
    "probe_success": "probe_success{job=\"blackbox\"}",
    "cpu_busy_unvalidated_24h": "100 * (1 - avg by(node) (rate(node_cpu_seconds_total{mode=\"idle\"}[24h])))",
    "cpu_accounting_rate_5m": "sum by(node) (rate(node_cpu_seconds_total{job=\"node-exporter\",mode!~\"guest.*\"}[5m])) / count by(node) (node_cpu_seconds_total{job=\"node-exporter\",mode=\"idle\"})",
    "memory_used_pct": "100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)",
    "root_free_bytes": "node_filesystem_avail_bytes{mountpoint=\"/\",fstype!=\"rootfs\"}",
    "oom_kills_24h": "increase(node_vmstat_oom_kill[24h])",
    "failed_units": "node_systemd_unit_state{state=\"failed\"} == 1",
    "textfile_errors": "node_textfile_scrape_error",
    "textfile_age": "time() - node_textfile_mtime_seconds",
    "collector_failures": "{__name__=~\"shipping_collector_section_failed|agent_nav_collector_section_failed\"} > 0",
    "gate_failures": "shipping_gate_step_failures > 0",
    "gate_duration": "shipping_gate_seconds",
    "gate_counts": "shipping_gate_runs_counted",
    "gate_fail_ratio": "shipping_gate_fail_ratio",
    "scrape_jobs": "count by(job) (up)",
    "journal_reader_metric_coverage": "count by(job,instance,node) (homelab_journal_reader_lines_total)",
    "journal_collector_success": "homelab_journal_metrics_collection_success",
    "journal_collector_age_seconds": "time() - homelab_journal_metrics_collection_timestamp_seconds",
    "log_writer_metric_coverage": "count by(job,instance,node) (loki_write_sent_entries_total)",
    "cpu_counter_resets_24h": "sum by(node,mode) (resets(node_cpu_seconds_total[24h])) > 0",
    "restart_signal": "count(node_systemd_service_restart_total)",
    "cpu_attribution": "count by(job) ({__name__=~\"process_cpu_seconds_total|container_cpu_usage_seconds_total|namedprocess_namegroup_cpu_seconds_total\"})",
    "gpu_util_max_24h": "max_over_time(nvidia_smi_utilization_gpu_ratio[24h])",
    "series": "prometheus_tsdb_head_series",
    "prometheus_memory": "process_resident_memory_bytes{job=\"prometheus\"}",
    "loki_memory": "process_resident_memory_bytes{job=\"loki\"}"
}

LOKI_QUERIES = {
    "journal_volume_24h": "sum by(host) (count_over_time({job=\"host-journal\"}[24h]))",
    "journal_error_keyword_matches_24h": "topk(12, sum by(host,unit) (count_over_time({job=\"host-journal\"} |~ \"(?i)(error|failed|fatal)\" [24h])))",
    "gate_failures_24h": "sum by(host) (count_over_time({job=\"platform\",kind=\"gate\"} | logfmt | result=\"fail\" [24h]))"
}


def query(base_url: str, path: str, expression: str, observed_at: str) -> dict[str, object]:
    params = urllib.parse.urlencode({"query": expression, "time": observed_at})
    try:
        with urllib.request.urlopen(base_url.rstrip("/") + path + "?" + params, timeout=45) as response:
            result: object = json.load(response)
        if not isinstance(result, dict):
            raise ValueError("API response must be an object")
        if result.get("status") != "success":
            error_type = result.get("errorType")
            # API error classes are bounded; never copy arbitrary response text.
            known_errors = {"timeout", "canceled", "execution", "bad_data", "internal", "unavailable", "not_found"}
            return {"query": expression, "status": "error", "error": error_type if isinstance(error_type, str) and error_type in known_errors else "api_error"}
        data: object = result.get("data")
        warnings: object = result.get("warnings", [])
        if not isinstance(data, dict) or not isinstance(data.get("result"), list):
            raise ValueError("API result must be an array")
        if not isinstance(warnings, list) or not all(isinstance(item, str) for item in warnings):
            raise ValueError("API warnings must be strings")
        return {
            "query": expression,
            "status": "success",
            "warnings": warnings,
            "result": data["result"],
        }
    except Exception as error:
        # Keep credentials/URLs and arbitrary server response bodies out of artifacts.
        return {"query": expression, "status": "error", "error": type(error).__name__}


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Read-only fleet snapshot; empty results remain unknown, never zero."
    )
    parser.add_argument("--prometheus-url", required=True)
    parser.add_argument("--loki-url", required=True)
    args = parser.parse_args()
    observed_at = datetime.datetime.now(datetime.timezone.utc).isoformat()
    observations: dict[str, dict[str, object]] = {}
    for base_url, path, queries in [
        (args.prometheus_url, "/api/v1/query", PROMETHEUS_QUERIES),
        (args.loki_url, "/loki/api/v1/query", LOKI_QUERIES),
    ]:
        for name, expression in queries.items():
            observations[name] = query(base_url, path, expression, observed_at)
    print(json.dumps({"observed_at": observed_at, "queries": observations}, indent=2))
    return int(any(result["status"] != "success" for result in observations.values()))


if __name__ == "__main__":
    sys.exit(main())
