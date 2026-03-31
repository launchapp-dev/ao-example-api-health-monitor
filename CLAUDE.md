# API Health Monitor — Agent Context

## What This Project Does

Monitors a configured set of API endpoints at scheduled intervals (every 5 minutes),
detects performance degradation and outages, creates GitHub issues for incidents, and
produces weekly SLA compliance reports. Three separate workflows handle different time
horizons: real-time alerting, hourly trend analysis, and weekly compliance reporting.

## Key Files

- `config/endpoints.yaml` — list of endpoints to monitor (edit this to add your APIs)
- `config/sla-targets.yaml` — uptime and latency SLA targets per endpoint group
- `config/alerting.yaml` — GitHub repo for incident issues, escalation thresholds
- `data/probes/` — raw probe results from each 5-minute run
- `data/health-status.json` — current health state per endpoint (written by health-analyzer)
- `data/incidents/active.json` — map of endpoint name → GitHub issue number for open incidents
- `data/incidents/history.json` — append-only log of all resolved incidents
- `output/dashboard.md` — live dashboard regenerated every hour

## Workflow Flow

**health-check** (every 5 min):
1. `probe-endpoints` (command) — curl probes all endpoints, writes `data/probes/{ts}.json`
2. `analyze-health` (agent) — reads probe history + memory baselines, emits verdict
3. `manage-incidents` (agent) — only runs on degraded/down verdict, manages GitHub issues

**hourly-summary** (every hour):
1. `aggregate-probes` (command) — aggregates last hour of probes into hourly summary
2. `update-dashboard` (agent) — regenerates dashboard.md and status-page.md

**weekly-sla-report** (Mondays 9am UTC):
1. `collect-weekly-data` (command) — aggregates 7 days of hourly summaries
2. `generate-sla-report` (agent) — writes SLA report to output/reports/
3. `file-sla-issues` (agent) — only on breach/at-risk, creates GitHub summary issue

## Decision Verdicts

**analyze-health:**
- `healthy` → skip incident management, end workflow
- `degraded` → proceed to manage-incidents (latency spike or intermittent errors)
- `down` → proceed to manage-incidents (high error rate or consecutive failures)

**generate-sla-report:**
- `compliant` → end workflow
- `breach` → file a GitHub issue summarizing SLA violations
- `at-risk` → file a GitHub issue with warning (trending toward breach)

## Data Formats

### Probe file (data/probes/{timestamp}.json)
```json
{
  "probe_time": "2026-03-31T12:00:00Z",
  "total_endpoints": 5,
  "successful_probes": 4,
  "failed_probes": 1,
  "probes": [
    {
      "name": "main-api",
      "url": "https://api.example.com/health",
      "status_code": 200,
      "expected_status": 200,
      "latency_ms": 145,
      "connect_ms": 12,
      "ttfb_ms": 98,
      "healthy": true,
      "error": "",
      "timestamp": "2026-03-31T12:00:01Z"
    }
  ]
}
```

### Health status (data/health-status.json)
```json
{
  "timestamp": "2026-03-31T12:00:05Z",
  "overall": "degraded",
  "endpoints": {
    "main-api": {
      "status": "healthy",
      "current_latency_ms": 145,
      "baseline_latency_ms": 130,
      "error_rate_1h": 0.0,
      "trend": "stable"
    }
  }
}
```

### Active incidents (data/incidents/active.json)
```json
{
  "auth-service": 42,
  "user-api": 43
}
```

## Memory Knowledge Graph Keys

The health-analyzer agent stores baseline data in the memory MCP using these key patterns:
- `baseline:{endpoint-name}` → rolling average latency in ms
- `availability:{endpoint-name}` → rolling availability percentage

## Important Notes for Agents

- The probe script always exits 0 — individual endpoint failures are recorded as data, not errors
- Baseline latencies use exponential moving average: `new = 0.9 * old + 0.1 * current`
- Only update baselines for endpoints that are currently healthy (don't skew baseline with outage data)
- The `active.json` file must be updated atomically — read → modify → write, never partial writes
- GitHub issue numbers in active.json are integers, not strings
- Never create duplicate GitHub issues for the same endpoint — check active.json first
