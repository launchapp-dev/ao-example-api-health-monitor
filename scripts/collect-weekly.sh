#!/usr/bin/env bash
# collect-weekly.sh — aggregate the past 7 days of hourly summaries into a weekly summary
# Reads data/summaries/hourly/**/*.json, writes data/summaries/weekly/{date}.json

set -euo pipefail

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Week anchor = Monday of current week (ISO week)
WEEK_DATE=$(python3 -c "
from datetime import datetime, timedelta
today = datetime.utcnow().date()
# Go back to most recent Monday
monday = today - timedelta(days=today.weekday())
print(monday.strftime('%Y-%m-%d'))
")

WEEKLY_DIR="data/summaries/weekly"
mkdir -p "$WEEKLY_DIR"

python3 - <<PYEOF
import json
import os
from datetime import datetime, timedelta
from pathlib import Path
from collections import defaultdict

week_start_str = "$WEEK_DATE"
now_str = "$NOW"
week_start = datetime.strptime(week_start_str, "%Y-%m-%d")
week_end = week_start + timedelta(days=7)

hourly_root = Path("data/summaries/hourly")
weekly_dir = Path("$WEEKLY_DIR")

# Gather hourly summaries for the 7-day window
all_hourly = []
for day_offset in range(7):
    day = week_start + timedelta(days=day_offset)
    day_str = day.strftime("%Y-%m-%d")
    day_dir = hourly_root / day_str
    if not day_dir.exists():
        continue
    for f in sorted(day_dir.glob("*.json")):
        try:
            with open(f) as fin:
                data = json.load(fin)
            data["_source_day"] = day_str
            all_hourly.append(data)
        except (json.JSONDecodeError, KeyError):
            pass

if not all_hourly:
    print(f"No hourly summaries found for week of {week_start_str}")
    summary = {
        "week_start": week_start_str,
        "aggregated_at": now_str,
        "hours_available": 0,
        "endpoints": {},
    }
    with open(weekly_dir / f"{week_start_str}.json", "w") as fout:
        json.dump(summary, fout, indent=2)
    exit(0)

# Aggregate across all hours
endpoint_agg = defaultdict(lambda: {
    "uptime_samples": [],
    "avg_latencies": [],
    "p95_latencies": [],
    "p99_latencies": [],
    "total_probes": 0,
    "total_errors": 0,
})

for h in all_hourly:
    for name, ep in h.get("endpoints", {}).items():
        agg = endpoint_agg[name]
        uptime = ep.get("uptime_pct")
        if uptime is not None:
            agg["uptime_samples"].append(uptime)
        if ep.get("avg_latency_ms", -1) > 0:
            agg["avg_latencies"].append(ep["avg_latency_ms"])
        if ep.get("p95_latency_ms", -1) > 0:
            agg["p95_latencies"].append(ep["p95_latency_ms"])
        if ep.get("p99_latency_ms", -1) > 0:
            agg["p99_latencies"].append(ep["p99_latency_ms"])
        agg["total_probes"] += ep.get("total_probes", 0)
        agg["total_errors"] += ep.get("errors", 0)

def avg(lst):
    return round(sum(lst) / len(lst), 3) if lst else -1

def percentile(sorted_list, p):
    if not sorted_list:
        return -1
    idx = min(int(len(sorted_list) * p / 100), len(sorted_list) - 1)
    return sorted_list[idx]

summary_endpoints = {}
for name, agg in endpoint_agg.items():
    up_samples = agg["uptime_samples"]
    summary_endpoints[name] = {
        "weekly_uptime_pct": round(sum(up_samples) / len(up_samples), 4) if up_samples else 0.0,
        "min_hourly_uptime_pct": min(up_samples) if up_samples else 0.0,
        "avg_latency_ms": int(avg(agg["avg_latencies"])),
        "p95_latency_ms": int(avg(sorted(agg["p95_latencies"]))),
        "p99_latency_ms": int(avg(sorted(agg["p99_latencies"]))),
        "total_probes": agg["total_probes"],
        "total_errors": agg["total_errors"],
        "hours_sampled": len(up_samples),
    }

summary = {
    "week_start": week_start_str,
    "week_end": week_end.strftime("%Y-%m-%d"),
    "aggregated_at": now_str,
    "hours_available": len(all_hourly),
    "expected_hours": 168,
    "coverage_pct": round(len(all_hourly) / 168 * 100, 1),
    "endpoints": summary_endpoints,
}

output_path = weekly_dir / f"{week_start_str}.json"
with open(output_path, "w") as fout:
    json.dump(summary, fout, indent=2)
print(f"Weekly summary written to {output_path}")
print(f"Aggregated {len(all_hourly)} hourly files across {len(summary_endpoints)} endpoints")
PYEOF

exit 0
