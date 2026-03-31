#!/usr/bin/env bash
set -euo pipefail

# Launch all 5 sidecar collectors, the OTel Simulator app, and the LakeEO Dashboard.
# Ctrl+C cleanly stops all processes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[start]${NC} $*"; }
label() { echo -e "${CYAN}[start]${NC} $*"; }

# Load .env
if [[ -f .env ]]; then
    set -a
    source .env
    set +a
    info "Loaded .env"
else
    echo -e "${RED}[start]${NC} .env file not found. Copy .env.example to .env and fill in values."
    exit 1
fi

# Derive bare host (strip https://)
export DATABRICKS_HOST_BARE="${DATABRICKS_HOST#https://}"
export DATABRICKS_HOST_BARE="${DATABRICKS_HOST_BARE#http://}"
info "Workspace: $DATABRICKS_HOST_BARE"

# Resolve collector binaries (prefer collectors/bin/, then PATH)
ALLOY_BIN="$(command -v alloy 2>/dev/null || echo "collectors/bin/alloy")"
OTELCOL_BIN="$(command -v otelcol-contrib 2>/dev/null || echo "collectors/bin/otelcol-contrib")"

# Track child PIDs for cleanup
PIDS=()
cleanup() {
    echo ""
    info "Shutting down..."
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null
    info "All processes stopped."
}
trap cleanup EXIT INT TERM

# ─── Sidecars ───────────────────────────────────────────────

label "Starting Fluent Bit on :4318 (logs)"
fluent-bit -c collectors/fluent-bit/fluent-bit.yaml &
PIDS+=($!)

label "Starting Telegraf on :4319 (metrics — gauges only)"
telegraf --config collectors/telegraf/telegraf.conf &
PIDS+=($!)

label "Starting Grafana Alloy on :4320 (logs + metrics + traces)"
"$ALLOY_BIN" run collectors/alloy/config.alloy &
PIDS+=($!)

label "Starting Vector on :4322 (logs + metrics)"
vector --config collectors/vector/vector.yaml &
PIDS+=($!)

label "Starting OTel Collector on :4323 (logs + metrics + traces)"
"$OTELCOL_BIN" --config collectors/otel-collector/otel-collector.yaml &
PIDS+=($!)

# Brief pause for collectors to bind ports
sleep 3

# ─── Apps ───────────────────────────────────────────────────

label "Starting OTel Simulator app on :8000"
cd app_otel_sim
uvicorn backend.server:app --host 0.0.0.0 --port 8000 &
PIDS+=($!)
cd "$SCRIPT_DIR"

label "Starting LakeEO Dashboard on :8001"
cd app_lake_eo
uvicorn backend.server:app --host 0.0.0.0 --port 8001 &
PIDS+=($!)
cd "$SCRIPT_DIR"

echo ""
info "=== All services running ==="
info ""
info "  Sidecars:"
info "    Fluent Bit     (logs)                → localhost:4318"
info "    Telegraf       (metrics/gauges)      → localhost:4319"
info "    Grafana Alloy  (logs+metrics+traces) → localhost:4320"
info "    Vector         (logs+metrics)        → localhost:4322"
info "    OTel Collector (logs+metrics+traces) → localhost:4323"
info ""
info "  Apps:"
info "    Simulator      → http://localhost:8000"
info "    LakeEO Dashboard  → http://localhost:8001"
info ""
info "Press Ctrl+C to stop all services."
echo ""

# Wait for any child to exit
wait
