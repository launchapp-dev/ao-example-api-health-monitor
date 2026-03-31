#!/usr/bin/env bash
# aggregate-hourly.sh — aggregate the past hour of probe data into an hourly summary
# Reads data/probes/*.json, writes data/summaries/hourly/{date}/{hour}.json
# Prunes probe files older than 48 hours

set -euo pipefail

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
DATE=$(date -u +"%Y-%m-%d")
HOUR=$(date -u +"%H")
CUTOFF_EPOCH=$(date -u -d "1 hour ago" +%s 2>/dev/null || date -u -v-1H +%s)  # GNU/BSD compat
PRUNE_EPOCH=$(date -u -d "48 hours ago" +%s 2>/dev/null || date -u -v-48H +%s)

PROBES_DIR="data/probes"
SUMMARY_DIR="data/summaries/hourly/${DATE}"
mkdir -p "$SUMMARY_DIR"

python3 - <<PYEOF
import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path
from collections import defaultdict

probes_dir = Path("$PROBES_DIR")
summary_dir = Path("$SUMMARY_DIR")
cutoff_epoch = $CUTOFF_EPOCH
prune_epoch = $PRUNE_EPOCH

# Collect probe files from last hour
probe_files = []
for f in probes_dir.glob("*.json"):
    if f.name in ("latest-summary.json",):
        continue
    try:
        mtime = f.stat().st_mtime
        if mtime >= cutoff_epoch:
            probe_files.append(f)
    except OSError:
        pass

if not probe_files:
    print("No probe files found for the last hour — writing empty summary")
    summary = {"period": "$DATE/$HOUR:00", "endpoints": {}}
    with open(summary_dir / "$HOUR.json", "w") as fout:
        json.dump(summary, fout, indent=2)
    exit(0)

# Aggregate per endpoint
endpoint_data = defaultdict(lambda: {
    "probes": [],
    "latencies": [],
    "errors": 0,
    "total": 0,
})

for f in sorted(probe_files):
    try:
        with open(f) as fin:
            data = json.load(fin)
        for probe in data.get("probes", []):
            name = probe.get("name", "unknown")
            endpoint_data[name]["total"] += 1
            latency = probe.get("latency_ms", -1)
            if probe.get("healthy") and latency > 0:
                endpoint_data[name]["latencies"].append(latency)
            else:
                endpoint_data[name]["errors"] += 1
    except (json.JSONDecodeError, KeyError):
        pass

def percentile(sorted_list, p):
    if not sorted_list:
        return -1
    idx = int(len(sorted_list) * p / 100)
    idx = min(idx, len(sorted_list) - 1)
    return sorted_list[idx]

summary_endpoints = {}
for name, data in endpoint_data.items():
    total = data["total"]
    errors = data["errors"]
    latencies = sorted(data["latencies"])
    uptime_pct = round(((total - errors) / total * 100), 3) if total > 0 else 0.0

    summary_endpoints[name] = {
        "total_probes": total,
        "errors": errors,
        "uptime_pct": uptime_pct,
        "avg_latency_ms": int(sum(latencies) / len(latencies)) if latencies else -1,
        "min_latency_ms": latencies[0] if latencies else -1,
        "max_latency_ms": latencies[-1] if latencies else -1,
        "p50_latency_ms": percentile(latencies, 50),
        "p95_latency_ms": percentile(latencies, 95),
        "p99_latency_ms": percentile(latencies, 99),
    }

summary = {
    "period_date": "$DATE",
    "period_hour": int("$HOUR"),
    "aggregated_at": "$NOW",
    "probe_files_included": len(probe_files),
    "endpoints": summary_endpoints,
}

output_path = summary_dir / "$HOUR.json"
with open(output_path, "w") as fout:
    json.dump(summary, fout, indent=2)
print(f"Hourly summary written to {output_path}")
print(f"Aggregated {len(probe_files)} probe files across {len(summary_endpoints)} endpoints")

# Prune old probe files (older than 48 hours)
pruned = 0
for f in probes_dir.glob("*.json"):
    if f.name in ("latest-summary.json",):
        continue
    try:
        if f.stat().st_mtime < prune_epoch:
            f.unlink()
            pruned += 1
    except OSError:
        pass
if pruned:
    print(f"Pruned {pruned} probe files older than 48 hours")
PYEOF

exit 0
