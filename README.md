# API Health Monitor

Probes configured API endpoints every 5 minutes, detects latency spikes and error
rate increases, creates GitHub issues for sustained incidents, and produces weekly
SLA compliance reports.

## Workflow Diagram

```
Every 5 minutes (health-check)
┌─────────────────────────────────────────────────────────────────────┐
│                                                                     │
│  [probe-endpoints] ──cmd──► curl all endpoints, write probes/       │
│         │                                                           │
│         ▼                                                           │
│  [analyze-health] ──agent──► read history, detect anomalies         │
│         │                                                           │
│    verdict?                                                         │
│    ├─ healthy ──────────────────────────────────────────► END       │
│    ├─ degraded ─────────────────────────────────────────┐           │
│    └─ down ─────────────────────────────────────────────┤           │
│                                                         ▼           │
│                                              [manage-incidents]     │
│                                          create/update/close issues │
└─────────────────────────────────────────────────────────────────────┘

Every hour (hourly-summary)
┌──────────────────────────────────────────────────┐
│  [aggregate-probes] ──cmd──► hourly stats JSON   │
│         │                                        │
│         ▼                                        │
│  [update-dashboard] ──agent──► dashboard.md      │
│                                status-page.md    │
└──────────────────────────────────────────────────┘

Every Monday 9am (weekly-sla-report)
┌──────────────────────────────────────────────────────────────────┐
│  [collect-weekly-data] ──cmd──► weekly aggregate JSON            │
│         │                                                        │
│         ▼                                                        │
│  [generate-sla-report] ──agent──► sla-{date}.md                 │
│         │                                                        │
│    verdict?                                                      │
│    ├─ compliant ──────────────────────────────────────► END      │
│    ├─ breach ─────────────────────────────────────────┐          │
│    └─ at-risk ────────────────────────────────────────┤          │
│                                                       ▼          │
│                                          [file-sla-issues]       │
│                                      create GitHub issue         │
└──────────────────────────────────────────────────────────────────┘
```

## Quick Start

```bash
cd examples/api-health-monitor

# 1. Configure your endpoints
edit config/endpoints.yaml        # Add your API endpoints
edit config/sla-targets.yaml      # Set your SLA thresholds
edit config/alerting.yaml         # Set your GitHub repo for incidents

# 2. Set environment variables
export GITHUB_TOKEN=ghp_...       # GitHub PAT with issues:write

# 3. Start the daemon
ao daemon start --autonomous

# 4. Trigger a health check immediately (optional)
ao workflow run health-check

# Watch the dashboard update
cat output/dashboard.md
```

## Agents

| Agent | Model | Role |
|---|---|---|
| **endpoint-prober** | claude-haiku-4-5 | Validates probe results, flags malformed outputs, prepares clean summary |
| **health-analyzer** | claude-sonnet-4-6 | Detects latency anomalies, calculates error rates, correlates failures across services |
| **incident-manager** | claude-sonnet-4-6 | Creates/updates/closes GitHub issues for incidents, manages incident lifecycle |
| **sla-reporter** | claude-sonnet-4-6 | Generates hourly dashboards, status pages, and weekly SLA compliance reports |

## AO Features Demonstrated

- **Scheduled workflows** — three independent schedules: every 5 min, hourly, weekly Monday 9am
- **Command phases** — `curl -w` for precise timing metrics (status code, latency, TTFB, connect time)
- **Multi-agent pipeline** — prober → analyzer → incident manager, each with a focused role
- **Decision contracts** — `analyze-health` emits `healthy|degraded|down` to route phase execution
- **Phase routing** — healthy probes skip incident management; degraded/down routes to GitHub issue creation
- **Memory MCP** — stores learned latency baselines per endpoint (exponential moving average)
- **Sequential-thinking MCP** — health-analyzer uses structured reasoning for multi-endpoint failure correlation
- **Output contracts** — probe data and health status follow strict JSON schemas across phases
- **Rework-style routing** — SLA report routes to `file-sla-issues` only on `breach` or `at-risk` verdicts
- **Data lifecycle management** — probe files auto-pruned after 48h; summaries retained per config

## Requirements

### Environment Variables
| Variable | Required | Purpose |
|---|---|---|
| `GITHUB_TOKEN` | Yes | Create/update/close GitHub issues for incidents |

### Tools
- `curl` — endpoint probing (standard on macOS/Linux)
- `python3` with `pyyaml` — config parsing and data aggregation
- `bc` — floating-point latency calculations

Install pyyaml if needed:
```bash
pip3 install pyyaml
```

### MCP Servers (installed automatically via npx)
- `@modelcontextprotocol/server-filesystem` — read/write probe data and reports
- `@modelcontextprotocol/server-memory` — persistent baseline latency storage
- `@modelcontextprotocol/server-sequential-thinking` — structured failure correlation
- `gh-cli-mcp` — GitHub issue creation and management

## Directory Layout

```
config/
├── endpoints.yaml          # Endpoints to monitor
├── sla-targets.yaml        # SLA targets per endpoint/group
├── alerting.yaml           # Alert thresholds, GitHub repo
└── probe-config.yaml       # Probe settings (timeout, retries)

scripts/
├── probe-endpoints.sh      # curl-based probing with timing
├── aggregate-hourly.sh     # Aggregate probe data hourly
└── collect-weekly.sh       # Collect weekly data for SLA reports

data/
├── probes/{timestamp}.json         # Raw probe results
├── probes/latest-summary.json      # Most recent probe (quick access)
├── health-status.json              # Current health per endpoint
├── incidents/
│   ├── active.json                 # Open incidents (endpoint → issue#)
│   └── history.json                # All resolved incidents
└── summaries/
    ├── hourly/{date}/{hour}.json   # Hourly aggregated metrics
    └── weekly/{date}.json          # Weekly aggregated metrics

output/
├── dashboard.md                    # Live dashboard (updated hourly)
├── status-page.md                  # Public-facing status page
└── reports/sla-{date}.md           # Weekly SLA compliance reports
```
