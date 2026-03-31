#!/usr/bin/env bash
# probe-endpoints.sh — curl-based endpoint probing with timing metrics
# Reads config/endpoints.yaml, probes each endpoint, writes data/probes/{timestamp}.json
# Always exits 0 — individual failures are data points, not script failures

set -euo pipefail

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
SAFE_TS=$(echo "$TIMESTAMP" | tr ':' '-')
OUTPUT_DIR="data/probes"
OUTPUT_FILE="$OUTPUT_DIR/${SAFE_TS}.json"
TIMEOUT=30
USER_AGENT="AO-HealthMonitor/1.0"

mkdir -p "$OUTPUT_DIR"

# Parse endpoints.yaml with python3 (available on macOS/Linux)
ENDPOINTS_JSON=$(python3 - <<'PYEOF'
import yaml, json, sys

with open("config/endpoints.yaml") as f:
    config = yaml.safe_load(f)

endpoints = config.get("endpoints", [])
print(json.dumps(endpoints))
PYEOF
)

probe_endpoint() {
    local name="$1"
    local url="$2"
    local method="${3:-GET}"
    local expected_status="${4:-200}"
    local body="${5:-}"
    local content_type="${6:-}"

    local start_ts
    start_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Build curl args
    local curl_args=(
        -s
        -o /tmp/probe_body_$$
        -w "%{http_code}|%{time_total}|%{time_connect}|%{time_starttransfer}|%{size_download}"
        --max-time "$TIMEOUT"
        -L
        --max-redirs 3
        -A "$USER_AGENT"
        -X "$method"
    )

    if [[ -n "$body" ]]; then
        curl_args+=(-d "$body")
    fi
    if [[ -n "$content_type" ]]; then
        curl_args+=(-H "Content-Type: $content_type")
    fi
    curl_args+=("$url")

    local result
    local exit_code=0
    result=$(curl "${curl_args[@]}" 2>/dev/null) || exit_code=$?

    local status_code latency_ms connect_ms ttfb_ms size_bytes
    local error_msg=""

    if [[ $exit_code -eq 0 ]] && [[ -n "$result" ]]; then
        IFS='|' read -r status_code time_total time_connect time_ttfb size_download <<< "$result"
        # Convert seconds to milliseconds
        latency_ms=$(echo "$time_total * 1000" | bc | cut -d. -f1)
        connect_ms=$(echo "$time_connect * 1000" | bc | cut -d. -f1)
        ttfb_ms=$(echo "$time_ttfb * 1000" | bc | cut -d. -f1)
        size_bytes="$size_download"
    elif [[ $exit_code -eq 28 ]]; then
        status_code=0
        latency_ms=-1
        connect_ms=-1
        ttfb_ms=-1
        size_bytes=0
        error_msg="timeout after ${TIMEOUT}s"
    elif [[ $exit_code -eq 7 ]]; then
        status_code=0
        latency_ms=-1
        connect_ms=-1
        ttfb_ms=-1
        size_bytes=0
        error_msg="connection refused"
    else
        status_code=0
        latency_ms=-1
        connect_ms=-1
        ttfb_ms=-1
        size_bytes=0
        error_msg="curl error code $exit_code"
    fi

    # Calculate content hash for change detection
    local content_hash=""
    if [[ -f /tmp/probe_body_$$ ]] && [[ -s /tmp/probe_body_$$ ]]; then
        content_hash=$(md5sum /tmp/probe_body_$$ 2>/dev/null | cut -d' ' -f1 || echo "")
    fi
    rm -f /tmp/probe_body_$$

    local healthy=false
    if [[ "$status_code" == "$expected_status" ]]; then
        healthy=true
    fi

    # Emit JSON for this probe
    python3 -c "
import json
print(json.dumps({
    'name': '$name',
    'url': '$url',
    'method': '$method',
    'status_code': int('$status_code') if '$status_code' else 0,
    'expected_status': int('$expected_status'),
    'latency_ms': int('$latency_ms') if '$latency_ms' else -1,
    'connect_ms': int('$connect_ms') if '$connect_ms' else -1,
    'ttfb_ms': int('$ttfb_ms') if '$ttfb_ms' else -1,
    'size_bytes': int('$size_bytes') if '$size_bytes' else 0,
    'content_hash': '$content_hash',
    'healthy': $([[ '$healthy' == 'true' ]] && echo 'True' || echo 'False'),
    'error': '$error_msg',
    'timestamp': '$start_ts'
}))
"
}

# Probe all endpoints in parallel, collect results
RESULTS=()

while IFS= read -r endpoint_json; do
    name=$(echo "$endpoint_json" | python3 -c "import json,sys; e=json.loads(sys.stdin.read()); print(e['name'])")
    url=$(echo "$endpoint_json" | python3 -c "import json,sys; e=json.loads(sys.stdin.read()); print(e['url'])")
    method=$(echo "$endpoint_json" | python3 -c "import json,sys; e=json.loads(sys.stdin.read()); print(e.get('method','GET'))")
    expected=$(echo "$endpoint_json" | python3 -c "import json,sys; e=json.loads(sys.stdin.read()); print(e.get('expected_status',200))")
    body=$(echo "$endpoint_json" | python3 -c "import json,sys; e=json.loads(sys.stdin.read()); print(e.get('body',''))")
    ctype=$(echo "$endpoint_json" | python3 -c "import json,sys; e=json.loads(sys.stdin.read()); h=e.get('headers',{}); print(h.get('Content-Type',''))")

    result=$(probe_endpoint "$name" "$url" "$method" "$expected" "$body" "$ctype")
    RESULTS+=("$result")
done < <(echo "$ENDPOINTS_JSON" | python3 -c "
import json, sys
endpoints = json.loads(sys.stdin.read())
for e in endpoints:
    print(json.dumps(e))
")

# Build final output JSON
python3 - <<PYEOF
import json

timestamp = "$TIMESTAMP"
results = []
raw = """$(printf '%s\n' "${RESULTS[@]}")"""
for line in raw.strip().split('\n'):
    line = line.strip()
    if line:
        try:
            results.append(json.loads(line))
        except json.JSONDecodeError:
            pass

output = {
    "probe_time": timestamp,
    "total_endpoints": len(results),
    "successful_probes": sum(1 for r in results if r.get("healthy", False)),
    "failed_probes": sum(1 for r in results if not r.get("healthy", False)),
    "probes": results
}

with open("$OUTPUT_FILE", "w") as f:
    json.dump(output, f, indent=2)

# Also write as latest-summary for quick agent access
with open("data/probes/latest-summary.json", "w") as f:
    json.dump(output, f, indent=2)

print(f"Probed {output['total_endpoints']} endpoints: "
      f"{output['successful_probes']} healthy, {output['failed_probes']} failed")
print(f"Results written to $OUTPUT_FILE")
PYEOF

exit 0
