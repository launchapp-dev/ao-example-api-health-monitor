# API Health Monitor — Build Plan

## Overview

API endpoint health monitoring pipeline — probes configured endpoints at scheduled
intervals, tracks response times and status codes, detects latency spikes and error
rate increases, creates GitHub issues for sustained incidents, and produces weekly
SLA compliance reports.

All operations use real, existing tools: `curl` via command phases for probing,
`jq` for response parsing, fetch MCP for flexible HTTP requests, memory MCP for
historical baselines, GitHub MCP for incident issue creation, and filesystem MCP
for data persistence.

---

## Agents (4)

| Agent | Model | Role |
|---|---|---|
| **endpoint-prober** | claude-haiku-4-5 | Fast health checks — probes endpoints, records status codes, latency, response validation |
| **health-analyzer** | claude-sonnet-4-6 | Analyzes probe results — detects anomalies, latency spikes, error rate trends, correlates failures |
| **incident-manager** | claude-sonnet-4-6 | Creates/updates GitHub issues for incidents, manages incident lifecycle (open/monitoring/resolved) |
| **sla-reporter** | claude-sonnet-4-6 | Generates SLA compliance reports — uptime percentages, latency percentiles, breach alerts |

### MCP Servers Used by Agents

- **filesystem** — all agents read/write JSON data files and reports
- **github** (gh-cli-mcp) — incident-manager creates/updates/closes GitHub issues for incidents
- **fetch** (@modelcontextprotocol/server-fetch) — endpoint-prober uses for HTTP requests to monitored endpoints
- **memory** (@modelcontextprotocol/server-memory) — health-analyzer stores baseline latencies and historical availability data
- **sequential-thinking** — health-analyzer uses for complex failure correlation reasoning

---

## Workflows (3)

### 1. `health-check` (primary — scheduled every 5 minutes)

Core monitoring loop: probe endpoints -> analyze -> act on incidents.

**Phases:**

1. **probe-endpoints** (command)
   - Script: `scripts/probe-endpoints.sh`
   - Reads endpoint list from `config/endpoints.yaml`
   - For each endpoint, runs `curl -w` with timing variables:
     - HTTP status code, total time, connect time, TLS time, TTFB
     - Response body hash for content change detection
     - Response header checks (content-type, cache headers)
   - Writes results to `data/probes/{timestamp}.json`
   - Each entry: `{url, method, status_code, latency_ms, connect_ms, ttfb_ms, content_hash, headers, timestamp, error}`
   - Timeout: 30 seconds per endpoint, 120 seconds total
   - Exit 0 always (individual failures recorded as probe results, not script failures)

2. **analyze-health** (agent: health-analyzer)
   - Reads latest probe from `data/probes/`
   - Reads recent probe history from `data/probes/` (last 12 probes = 1 hour)
   - Reads baseline data from memory MCP (historical averages)
   - For each endpoint, calculates:
     - **Current status**: healthy (2xx, latency < 2x baseline) / degraded (latency spike or intermittent errors) / down (5xx, timeout, connection refused)
     - **Latency analysis**: current vs baseline, p50/p95/p99 over last hour
     - **Error rate**: error count / total probes over last hour
     - **Trend**: improving / stable / degrading (based on last 12 data points)
   - Detects cross-service correlation (if multiple related endpoints fail simultaneously)
   - Updates memory MCP with latest baseline calculations
   - Writes `data/health-status.json` with per-endpoint status
   - Decision contract: `{verdict: "healthy" | "degraded" | "down", affected_endpoints, reasoning}`
   - Uses sequential-thinking for complex multi-endpoint failure correlation

3. **manage-incidents** (agent: incident-manager)
   - Only runs when verdict is "degraded" or "down"
   - Reads `data/health-status.json` and `data/incidents/active.json`
   - For each affected endpoint:
     - **New incident**: creates GitHub issue with labels `incident`, `severity:{level}`, `endpoint:{name}`
       - Issue body includes: affected URL, error details, latency data, timeline, related endpoints
     - **Existing incident (still failing)**: adds comment to existing issue with latest data
     - **Existing incident (now resolved)**: adds resolution comment, closes issue, records duration
   - Uses gh-cli-mcp for all GitHub operations
   - Writes `data/incidents/active.json` (maps endpoint -> issue number)
   - Writes `data/incidents/history.json` (append-only incident log)

**Routing:**
- `analyze-health` on verdict "healthy" -> skip manage-incidents, end
- `analyze-health` on verdict "degraded" or "down" -> proceed to manage-incidents

### 2. `hourly-summary` (scheduled every hour)

Aggregates probe data into hourly summaries for trend analysis.

**Phases:**

1. **aggregate-probes** (command)
   - Script: `scripts/aggregate-hourly.sh`
   - Reads all probe files from the last hour in `data/probes/`
   - Calculates per-endpoint: uptime %, avg latency, p95 latency, error count, max latency
   - Writes summary to `data/summaries/hourly/{date}/{hour}.json`
   - Prunes probe files older than 48 hours (keeps summaries)

2. **update-dashboard** (agent: sla-reporter)
   - Reads hourly summaries from `data/summaries/hourly/`
   - Reads endpoint config from `config/endpoints.yaml`
   - Generates `output/dashboard.md`:
     - Per-endpoint: current status, last-24h uptime %, avg latency, incident count
     - Overall: system health score, endpoints meeting SLA, endpoints breaching SLA
     - Timeline: last 24 hours as a text-based availability timeline
   - Generates `output/status-page.md` — simplified public-facing status page format

### 3. `weekly-sla-report` (scheduled every Monday 9am)

Comprehensive SLA compliance report for the past week.

**Phases:**

1. **collect-weekly-data** (command)
   - Script: `scripts/collect-weekly.sh`
   - Reads all hourly summaries from the past 7 days
   - Reads incident history from `data/incidents/history.json`
   - Calculates per-endpoint: weekly uptime %, latency percentiles, total incidents, MTTR
   - Writes `data/summaries/weekly/{date}.json`

2. **generate-sla-report** (agent: sla-reporter)
   - Reads weekly summary and incident history
   - Reads SLA targets from `config/sla-targets.yaml`
   - Produces `output/reports/sla-{date}.md`:
     - **Executive summary**: overall compliance, breaches, key incidents
     - **Per-endpoint detail**: uptime vs target, latency vs target, incidents
     - **SLA compliance matrix**: endpoint x metric table with pass/fail
     - **Incident log**: each incident with duration, impact, resolution
     - **Trend analysis**: this week vs previous weeks
     - **Recommendations**: endpoints that are trending toward SLA breach
   - Decision contract: `{verdict: "compliant" | "breach" | "at-risk", breached_endpoints, reasoning}`

3. **file-sla-issues** (agent: incident-manager)
   - Only runs when verdict is "breach" or "at-risk"
   - Creates a GitHub issue summarizing SLA breaches for the week
   - Labels: `sla-breach`, `weekly-report`, `priority:high`
   - Tags relevant teams/endpoints in the issue body

---

## Decision Contracts

### analyze-health verdict
```json
{
  "verdict": "healthy | degraded | down",
  "affected_endpoints": ["api.example.com/health", "api.example.com/v2/status"],
  "error_rate": 0.15,
  "worst_latency_ms": 2340,
  "reasoning": "Two endpoints returning 503, correlated — likely shared backend issue"
}
```

### generate-sla-report verdict
```json
{
  "verdict": "compliant | breach | at-risk",
  "breached_endpoints": ["api.example.com/v2/users"],
  "overall_uptime_pct": 99.82,
  "sla_target_pct": 99.9,
  "reasoning": "One endpoint dropped below 99.9% target due to 45-minute outage on Thursday"
}
```

---

## Directory Layout

```
config/
├── endpoints.yaml          # Endpoints to monitor with expected behavior
├── sla-targets.yaml        # SLA targets per endpoint (uptime %, latency thresholds)
├── alerting.yaml           # Alert thresholds, GitHub repo for incidents
└── probe-config.yaml       # Probe settings: timeout, retries, intervals

scripts/
├── probe-endpoints.sh      # curl-based endpoint probing with timing
├── aggregate-hourly.sh     # Aggregate probe data into hourly summaries
└── collect-weekly.sh       # Collect weekly data for SLA reporting

data/
├── probes/{timestamp}.json             # Raw probe results per run
├── health-status.json                  # Latest health status per endpoint
├── incidents/
│   ├── active.json                     # Currently open incidents (endpoint -> issue#)
│   └── history.json                    # All incidents with resolution data
└── summaries/
    ├── hourly/{date}/{hour}.json       # Hourly aggregated metrics
    └── weekly/{date}.json              # Weekly aggregated metrics

output/
├── dashboard.md                        # Live dashboard (updated hourly)
├── status-page.md                      # Simplified status page format
└── reports/
    └── sla-{date}.md                   # Weekly SLA compliance reports
```

---

## Config Files

### config/endpoints.yaml
```yaml
endpoints:
  - name: main-api
    url: "https://api.example.com/health"
    method: GET
    expected_status: 200
    expected_latency_ms: 500
    tags: [critical, backend]
    group: core-api

  - name: auth-service
    url: "https://auth.example.com/status"
    method: GET
    expected_status: 200
    expected_latency_ms: 300
    headers:
      Accept: "application/json"
    tags: [critical, auth]
    group: core-api

  - name: user-api
    url: "https://api.example.com/v2/users/health"
    method: GET
    expected_status: 200
    expected_latency_ms: 800
    tags: [standard, backend]
    group: user-services

  - name: webhook-endpoint
    url: "https://api.example.com/webhooks/health"
    method: POST
    body: '{"test": true}'
    expected_status: 200
    expected_latency_ms: 1000
    headers:
      Content-Type: "application/json"
    tags: [standard, webhooks]
    group: integrations

  - name: cdn-assets
    url: "https://cdn.example.com/health.txt"
    method: GET
    expected_status: 200
    expected_latency_ms: 100
    tags: [standard, cdn]
    group: static
```

### config/sla-targets.yaml
```yaml
# SLA targets per group and per endpoint
defaults:
  uptime_pct: 99.9
  latency_p95_ms: 1000
  latency_p99_ms: 2000

groups:
  core-api:
    uptime_pct: 99.95
    latency_p95_ms: 500
    latency_p99_ms: 1000
  static:
    uptime_pct: 99.99
    latency_p95_ms: 200

overrides:
  auth-service:
    uptime_pct: 99.99    # Auth must be highly available
    latency_p95_ms: 300
```

### config/alerting.yaml
```yaml
github:
  repo: "your-org/api-incidents"         # Where to create incident issues
  labels_prefix: "api-monitor"           # Label prefix for all issues

thresholds:
  degraded:
    error_rate_pct: 5                    # >5% error rate = degraded
    latency_multiplier: 2.0             # >2x baseline latency = degraded
  down:
    error_rate_pct: 50                   # >50% error rate = down
    consecutive_failures: 3             # 3 consecutive failures = down

incident_rules:
  create_after_consecutive_failures: 2   # Create issue after 2 consecutive bad probes
  auto_resolve_after_healthy_probes: 3   # Close issue after 3 consecutive healthy probes
```

### config/probe-config.yaml
```yaml
probe:
  timeout_secs: 30           # Per-endpoint timeout
  retries: 1                 # Retry once on failure
  retry_delay_ms: 2000       # Wait 2s before retry
  user_agent: "AO-HealthMonitor/1.0"
  follow_redirects: true
  max_redirects: 3
  verify_ssl: true
```

---

## Schedules

```yaml
schedules:
  - id: health-check-loop
    cron: "*/5 * * * *"
    workflow_ref: health-check
    enabled: true

  - id: hourly-summary
    cron: "0 * * * *"
    workflow_ref: hourly-summary
    enabled: true

  - id: weekly-sla-report
    cron: "0 9 * * 1"
    workflow_ref: weekly-sla-report
    enabled: true
```

---

## Key Design Decisions

1. **Haiku for probing, Sonnet for analysis** — the endpoint-prober uses Haiku for fast,
   cheap health checks (it's mostly reading probe output). The health-analyzer and
   incident-manager use Sonnet for deeper reasoning about failure correlation and
   incident management.

2. **Command phases for probing** — `curl -w` gives precise timing data that's hard to
   replicate through an LLM agent. The probe script is deterministic and fast. Agent
   phases handle the analysis and decision-making where LLM reasoning adds value.

3. **Memory MCP for baselines** — historical latency baselines are stored in the memory
   MCP knowledge graph, allowing the analyzer to detect anomalies relative to learned
   normal behavior rather than static thresholds alone.

4. **Three-tier scheduling** — 5-minute probes catch issues fast, hourly summaries
   provide trend visibility, and weekly SLA reports give compliance oversight. Each
   tier has its own workflow to keep concerns separated.

5. **GitHub Issues as incident tracker** — rather than building a custom incident system,
   we use GitHub Issues with structured labels. This integrates with existing team
   workflows and provides a built-in audit trail.

6. **Graceful probe failures** — individual endpoint probe failures are recorded as data
   points, not script errors. The probe script always exits 0 so the pipeline continues.
   A timeout or connection error is a valid health data point.

7. **Auto-resolution** — incidents are automatically closed when the endpoint returns to
   healthy for a configurable number of consecutive probes, preventing stale issues.
