#!/usr/bin/env python3
"""AdGuard Home's own counters as node-exporter textfile metrics (modules/homelab/adguardhome.nix runs it minutely):
its control API on loopback has no Prometheus endpoint, and has no users, so nothing beyond this host reads it. The
totals cover AdGuard's statistics interval, not a counter's lifetime: they are gauges. A field this AdGuard does not
send leaves its series out, as does a statistics call that fails; an unreachable API writes homelab_dns_up 0 alone.
Usage: adguard-textfile.py URL OUT"""
import json
import os
import sys
import urllib.request

url, out = sys.argv[1].rstrip("/"), sys.argv[2]
lines = []


def get(path):
    with urllib.request.urlopen(url + path, timeout=10) as r:
        return json.load(r)


def gauge(name, value):
    if isinstance(value, bool):
        value = int(value)
    if isinstance(value, (int, float)):
        lines.append(f"homelab_dns_{name} {value}")


def fetch(path):
    try:
        return get(path)
    except (OSError, ValueError) as e:
        print(f"adguard-textfile: {url}{path} did not answer: {e}", file=sys.stderr)
        return None


status = fetch("/control/status")
gauge("up", int(bool(status and status.get("running"))))
stats = fetch("/control/stats") if status else None
if status:
    gauge("protection_enabled", status.get("protection_enabled"))
if stats:
    gauge("queries", stats.get("num_dns_queries"))
    gauge("blocked", stats.get("num_blocked_filtering"))
    gauge("avg_processing_seconds", stats.get("avg_processing_time"))
    hourly = stats.get("dns_queries")
    if stats.get("time_units") == "hours" and isinstance(hourly, list) and hourly:
        gauge("queries_this_hour", hourly[-1])
tmp = out + ".tmp"
with open(tmp, "w") as f:
    f.write("\n".join(lines) + "\n")
os.chmod(tmp, 0o644)
os.replace(tmp, out)
